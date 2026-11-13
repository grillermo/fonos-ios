import Foundation

/// Heavy work that iOS may kill the app in the middle of.
enum HeavyPhase: String, Codable, Sendable {
    case idle
    /// Download plus the first Core ML compile, which Dictus's ModelManager runs
    /// right after the files land. The compile is the memory peak.
    case installing
    /// Loading a downloaded model into memory and running its warm-up inference.
    case loading
    case transcribing
}

/// What this launch was doing, written to disk before each heavy step so that a
/// kill, which runs no code, still leaves evidence for the next launch.
struct TerminationBreadcrumb: Codable, Equatable, Sendable {
    var launchID: UUID
    var launchedAt: Date
    var phase: HeavyPhase
    var modelID: String?
    var phaseStartedAt: Date
    var updatedAt: Date
    var inBackground: Bool
    var memory: ProcessMemorySnapshot
    var peakFootprintMB: Int
    var memoryWarnings: Int
    var exitedCleanly: Bool
}

/// A previous launch that ended in the middle of heavy work.
struct UnexpectedExit: Codable, Equatable, Sendable, Identifiable {
    var id: UUID { breadcrumb.launchID }
    var breadcrumb: TerminationBreadcrumb
    var detectedAt: Date
    /// Set when MetricKit later delivers a crash diagnostic for this window, which
    /// means the exit was a crash rather than iOS reclaiming memory.
    var crashReported: Bool = false

    var summary: String {
        let b = breadcrumb
        let model = b.modelID ?? "no model"
        let seconds = Int(b.updatedAt.timeIntervalSince(b.phaseStartedAt))
        let place = b.inBackground ? "in the background" : "in the foreground"
        let cause = crashReported ? "Crashed" : "Killed (likely memory)"
        return "\(cause) while \(b.phase.rawValue) \(model) \(place), \(seconds)s in. " +
            "Last footprint \(b.memory.footprintMB) MB (peak \(b.peakFootprintMB) MB), " +
            "\(b.memory.availableMB) MB left, \(b.memoryWarnings) memory warning(s)."
    }
}

/// Detects launches that ended while loading or running an on-device model.
///
/// iOS gives an app no callback when it is killed for memory (jetsam). So the app
/// writes a breadcrumb before heavy work and updates it every second; if the next
/// launch finds a breadcrumb that is not idle and not marked clean, the previous
/// process died mid-work. A force quit in the app switcher looks the same; the
/// MetricKit counts in `ExitMetricsReporter` tell the two apart a day later.
final class TerminationWatch: @unchecked Sendable {
    static let shared = TerminationWatch(directory: defaultDirectory)

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TerminationWatch", isDirectory: true)
    }

    static let maxExits = 50

    private let lock = NSLock()
    private let directory: URL
    private let now: @Sendable () -> Date
    private let memory: @Sendable () -> ProcessMemorySnapshot
    private let heartbeatInterval: Duration
    private var current: TerminationBreadcrumb
    private var heartbeat: Task<Void, Never>?

    init(
        directory: URL,
        launchID: UUID = UUID(),
        now: @escaping @Sendable () -> Date = { Date() },
        memory: @escaping @Sendable () -> ProcessMemorySnapshot = { ProcessMemory.snapshot() },
        heartbeatInterval: Duration = .seconds(1)
    ) {
        self.directory = directory
        self.now = now
        self.memory = memory
        self.heartbeatInterval = heartbeatInterval
        let started = now()
        let snapshot = memory()
        current = TerminationBreadcrumb(
            launchID: launchID,
            launchedAt: started,
            phase: .idle,
            modelID: nil,
            phaseStartedAt: started,
            updatedAt: started,
            inBackground: false,
            memory: snapshot,
            peakFootprintMB: snapshot.footprintMB,
            memoryWarnings: 0,
            exitedCleanly: false
        )
    }

    var breadcrumbURL: URL { directory.appendingPathComponent("breadcrumb.json") }
    var exitsURL: URL { directory.appendingPathComponent("unexpected-exits.json") }

    // MARK: - Launch

    /// Call once per launch, before any heavy work. Returns the previous launch's
    /// unexpected exit, if it had one, after recording it.
    @discardableResult
    func beginLaunch() -> UnexpectedExit? {
        lock.lock()
        defer { lock.unlock() }
        var found: UnexpectedExit?
        if let previous: TerminationBreadcrumb = read(breadcrumbURL),
           !previous.exitedCleanly,
           previous.phase != .idle {
            let exit = UnexpectedExit(breadcrumb: previous, detectedAt: now())
            var exits: [UnexpectedExit] = read(exitsURL) ?? []
            exits.insert(exit, at: 0)
            write(Array(exits.prefix(Self.maxExits)), to: exitsURL)
            found = exit
        }
        write(current, to: breadcrumbURL)
        return found
    }

    /// Newest first.
    func recordedExits() -> [UnexpectedExit] {
        lock.lock()
        defer { lock.unlock() }
        return read(exitsURL) ?? []
    }

    func clearExits() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: exitsURL)
    }

    /// Marks every recorded exit whose last breadcrumb falls inside a crash
    /// diagnostic's time range as a crash.
    func markCrash(between start: Date, and end: Date) {
        lock.lock()
        defer { lock.unlock() }
        guard var exits: [UnexpectedExit] = read(exitsURL) else { return }
        var changed = false
        for index in exits.indices where !exits[index].crashReported {
            let updated = exits[index].breadcrumb.updatedAt
            if updated >= start, updated <= end {
                exits[index].crashReported = true
                changed = true
            }
        }
        if changed { write(exits, to: exitsURL) }
    }

    // MARK: - Phases

    var currentBreadcrumb: TerminationBreadcrumb {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Runs `operation` with the breadcrumb saying `phase`, sampling memory every
    /// heartbeat, and goes back to idle when it returns or throws.
    /// Runs in the caller's isolation (`#isolation`), so a `@MainActor` view can
    /// pass a closure that touches main-actor state.
    func during<T>(
        _ phase: HeavyPhase,
        modelID: String?,
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        enter(phase, modelID: modelID)
        defer { leave() }
        return try await operation()
    }

    func enter(_ phase: HeavyPhase, modelID: String?) {
        update { crumb, at in
            crumb.phase = phase
            crumb.modelID = modelID
            crumb.phaseStartedAt = at
        }
        startHeartbeat()
    }

    func leave() {
        stopHeartbeat()
        update { crumb, _ in
            crumb.phase = .idle
            crumb.modelID = nil
        }
    }

    func setInBackground(_ inBackground: Bool) {
        update { crumb, _ in crumb.inBackground = inBackground }
    }

    func noteMemoryWarning() {
        update { crumb, _ in crumb.memoryWarnings += 1 }
    }

    /// Only `applicationWillTerminate` calls this. iOS rarely calls it, which is
    /// fine: only non-idle breadcrumbs count as unexpected.
    func markCleanExit() {
        stopHeartbeat()
        update { crumb, _ in crumb.exitedCleanly = true }
    }

    /// Starts peak tracking over from the current footprint, so one transcription's
    /// peak is not mixed with an earlier model's.
    func resetPeak() {
        update { crumb, _ in crumb.peakFootprintMB = crumb.memory.footprintMB }
    }

    /// Takes a memory reading and persists it. The heartbeat calls this.
    func sample() {
        update { _, _ in }
    }

    // MARK: - Private

    private func update(_ change: (inout TerminationBreadcrumb, Date) -> Void) {
        let at = now()
        let snapshot = memory()
        lock.lock()
        defer { lock.unlock() }
        current.updatedAt = at
        current.memory = snapshot
        change(&current, at)
        current.peakFootprintMB = max(current.peakFootprintMB, snapshot.footprintMB)
        write(current, to: breadcrumbURL)
    }

    private func startHeartbeat() {
        let interval = heartbeatInterval
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
        lock.lock()
        heartbeat?.cancel()
        heartbeat = task
        lock.unlock()
    }

    private func stopHeartbeat() {
        lock.lock()
        heartbeat?.cancel()
        heartbeat = nil
        lock.unlock()
    }

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            // completeUntilFirstUserAuthentication: readable by a launch iOS makes
            // in the background after the first unlock (Dictus #868).
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Diagnostics must never take the app down.
        }
    }
}
