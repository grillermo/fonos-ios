import Foundation
import Network
import os.log

private let autoRetryLog = Logger(subsystem: "com.fonos.ios", category: "PendingRecordingAutoRetrier")

/// Retries pending recordings one at a time, oldest first, while the app is
/// open. There is no server probe: the oldest item's own retry is the test.
/// Text is saved and never copied, and recipe outputs don't fire.
@MainActor
final class PendingRecordingAutoRetrier: ObservableObject {
    static let waits: [TimeInterval] = [60, 120, 300, 900]

    @Published private(set) var isRetryingAll = false

    /// True while a recording or transcription runs. Set by `ContentView`.
    var isBusy: @MainActor () -> Bool = { false }
    /// Retries one recording without copying. Set by `ContentView`.
    var retry: @MainActor (PendingRecording) async throws -> Void = { _ in }

    private let store: PendingRecordingStore
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var isActive = false
    private var passTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var waitIndex = 0

    init(
        store: PendingRecordingStore = .shared,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.store = store
        self.sleep = sleep
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active { wakeUp() } else { cancelTimer() }
    }

    func networkBecameAvailable() {
        guard isActive else { return }
        wakeUp()
    }

    /// A kept recording has only just failed, so it arms the timer rather than
    /// retrying straight away.
    func recordingsChanged() {
        scheduleTimer()
    }

    /// Retries every item, including those auto-retry skips.
    func retryAll() async {
        guard !isRetryingAll else { return }
        isRetryingAll = true
        await passTask?.value
        cancelTimer()
        let task = Task { [weak self] in
            await self?.runPass(includeStopped: true)
            return
        }
        passTask = task
        await task.value
        passTask = nil
        isRetryingAll = false
        scheduleTimer()
    }

    private var hasEligibleItem: Bool {
        store.all().contains { $0.autoRetryStoppedAt == nil }
    }

    private func wakeUp() {
        waitIndex = 0
        cancelTimer()
        startPass()
    }

    private func startPass() {
        guard isActive, passTask == nil, hasEligibleItem else { return }
        passTask = Task { [weak self] in
            await self?.runPass(includeStopped: false)
            self?.passTask = nil
            self?.scheduleTimer()
        }
    }

    private func runPass(includeStopped: Bool) async {
        var tried: Set<UUID> = []
        while includeStopped || isActive, !isBusy() {
            let oldestFirst = store.all().reversed()
            guard let next = oldestFirst.first(where: {
                !tried.contains($0.id) && (includeStopped || $0.autoRetryStoppedAt == nil)
            }) else { return }
            tried.insert(next.id)
            do {
                try await retry(next)
                waitIndex = 0
            } catch {
                autoRetryLog.info("Retry of \(next.id.uuidString.prefix(8), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                switch PendingRecordingFailure.classify(error) {
                case .permanent, .gone: continue
                case .temporary, .busy: return
                }
            }
        }
    }

    private func scheduleTimer() {
        guard isActive, passTask == nil, timerTask == nil, hasEligibleItem else { return }
        let delay = Self.waits[min(waitIndex, Self.waits.count - 1)]
        waitIndex += 1
        timerTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.timerTask = nil
            self?.startPass()
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }
}

/// Reports when the phone has a usable network, so a pass starts as soon as it
/// comes back.
final class PendingNetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var started = false

    @MainActor
    func start(onSatisfied: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in onSatisfied() }
        }
        monitor.start(queue: DispatchQueue(label: "com.fonos.ios.pending-network"))
    }
}
