import Foundation
import Testing
@testable import FonosApp

struct OnDeviceSTTTests {
    @Test("MetricKit reports are stored newest first, one per period")
    func exitReportsStore() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exits-\(UUID().uuidString)", isDirectory: true)
        let reporter = ExitMetricsReporter(
            directory: directory,
            watch: TerminationWatch(directory: directory)
        )
        func report(day: Double, kills: Int) -> ExitCountsReport {
            ExitCountsReport(
                periodStart: Date(timeIntervalSince1970: day * 86_400),
                periodEnd: Date(timeIntervalSince1970: (day + 1) * 86_400),
                foregroundMemoryLimit: kills, foregroundAbnormal: 0, foregroundWatchdog: 0,
                backgroundMemoryLimit: 1, backgroundMemoryPressure: 0, backgroundAbnormal: 0
            )
        }
        reporter.store(report(day: 1, kills: 0))
        reporter.store(report(day: 2, kills: 2))
        reporter.store(report(day: 1, kills: 5))

        let stored = reporter.reports()
        #expect(stored.count == 2)
        #expect(stored.first?.memoryKills == 3)
        #expect(stored.last?.foregroundMemoryLimit == 5)
    }
}
