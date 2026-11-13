import Foundation
import MetricKit

/// One MetricKit exit-count report. iOS delivers these about once a day, covering
/// the previous day, so they confirm a kill after the fact rather than in real time.
struct ExitCountsReport: Codable, Equatable, Sendable, Identifiable {
    var id: Date { periodStart }
    var periodStart: Date
    var periodEnd: Date
    var foregroundMemoryLimit: Int
    var foregroundAbnormal: Int
    var foregroundWatchdog: Int
    var backgroundMemoryLimit: Int
    var backgroundMemoryPressure: Int
    var backgroundAbnormal: Int

    /// Kills for using too much memory, in either state.
    var memoryKills: Int { foregroundMemoryLimit + backgroundMemoryLimit }
}

/// Subscribes to MetricKit. Exit counts are stored for the On-device Models screen;
/// crash diagnostics re-label matching `UnexpectedExit`s as crashes.
final class ExitMetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = ExitMetricsReporter(directory: TerminationWatch.defaultDirectory, watch: .shared)

    static let maxReports = 30

    private let lock = NSLock()
    private let directory: URL
    private let watch: TerminationWatch

    init(directory: URL, watch: TerminationWatch) {
        self.directory = directory
        self.watch = watch
    }

    var reportsURL: URL { directory.appendingPathComponent("exit-counts.json") }

    func start() {
        MXMetricManager.shared.add(self)
    }

    /// Newest first.
    func reports() -> [ExitCountsReport] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: reportsURL) else { return [] }
        return (try? JSONDecoder().decode([ExitCountsReport].self, from: data)) ?? []
    }

    func store(_ report: ExitCountsReport) {
        lock.lock()
        defer { lock.unlock() }
        var all: [ExitCountsReport] = []
        if let data = try? Data(contentsOf: reportsURL) {
            all = (try? JSONDecoder().decode([ExitCountsReport].self, from: data)) ?? []
        }
        all.removeAll { $0.periodStart == report.periodStart }
        all.insert(report, at: 0)
        all.sort { $0.periodStart > $1.periodStart }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(all.prefix(Self.maxReports))) {
            try? data.write(to: reportsURL, options: .atomic)
        }
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let foreground = exits.foregroundExitData
            let background = exits.backgroundExitData
            store(ExitCountsReport(
                periodStart: payload.timeStampBegin,
                periodEnd: payload.timeStampEnd,
                foregroundMemoryLimit: foreground.cumulativeMemoryResourceLimitExitCount,
                foregroundAbnormal: foreground.cumulativeAbnormalExitCount,
                foregroundWatchdog: foreground.cumulativeAppWatchdogExitCount,
                backgroundMemoryLimit: background.cumulativeMemoryResourceLimitExitCount,
                backgroundMemoryPressure: background.cumulativeMemoryPressureExitCount,
                backgroundAbnormal: background.cumulativeAbnormalExitCount
            ))
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty {
            watch.markCrash(between: payload.timeStampBegin, and: payload.timeStampEnd)
        }
    }
}
