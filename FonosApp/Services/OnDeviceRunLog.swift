import Foundation

/// One on-device transcription, kept so the models can be compared side by side.
struct OnDeviceRun: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var modelID: String
    var finishedAt: Date
    var audioSeconds: Double
    var loadMilliseconds: Int
    var transcribeMilliseconds: Int
    var peakFootprintMB: Int
    var characters: Int

    /// Seconds of audio per second of work; above 1 is faster than real time.
    var realTimeFactor: Double {
        transcribeMilliseconds > 0 ? audioSeconds * 1000 / Double(transcribeMilliseconds) : 0
    }
}

final class OnDeviceRunLog: @unchecked Sendable {
    static let shared = OnDeviceRunLog(
        url: TerminationWatch.defaultDirectory.appendingPathComponent("on-device-runs.json")
    )
    static let maxRuns = 200

    private let lock = NSLock()
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    /// Newest first.
    func runs() -> [OnDeviceRun] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    func latest(for modelID: String) -> OnDeviceRun? {
        runs().first { $0.modelID == modelID }
    }

    func append(_ run: OnDeviceRun) {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        all.insert(run, at: 0)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(Array(all.prefix(Self.maxRuns))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() -> [OnDeviceRun] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([OnDeviceRun].self, from: data)) ?? []
    }
}
