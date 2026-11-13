import Foundation
import Testing
@testable import FonosApp

/// Fake clock and memory source shared with the watch under test.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_000)
    private var footprint = 100

    var now: Date { lock.withLock { time } }
    var memory: ProcessMemorySnapshot {
        lock.withLock { ProcessMemorySnapshot(footprintMB: footprint, availableMB: 3_000 - footprint) }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func setFootprint(_ mb: Int) { lock.withLock { footprint = mb } }
}

struct TerminationWatchTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TerminationWatchTests-\(UUID().uuidString)", isDirectory: true)

    private func makeWatch(_ probe: Probe) -> TerminationWatch {
        TerminationWatch(
            directory: directory,
            now: { probe.now },
            memory: { probe.memory },
            heartbeatInterval: .seconds(3_600)
        )
    }

    @Test("A launch that ends while loading is reported by the next launch")
    func killDuringLoadIsReported() throws {
        let probe = Probe()
        let first = makeWatch(probe)
        #expect(first.beginLaunch() == nil)
        first.enter(.loading, modelID: "openai_whisper-medium")
        probe.advance(12)
        probe.setFootprint(2_900)
        first.sample()
        // No leave(): the process "dies" here.

        let second = makeWatch(probe)
        let exit = try #require(second.beginLaunch())
        #expect(exit.breadcrumb.phase == .loading)
        #expect(exit.breadcrumb.modelID == "openai_whisper-medium")
        #expect(exit.breadcrumb.peakFootprintMB == 2_900)
        #expect(exit.summary.contains("Killed (likely memory) while loading openai_whisper-medium"))
        #expect(exit.summary.contains("12s in"))
        #expect(second.recordedExits().count == 1)
    }

    @Test("A launch that was idle when it ended is not reported")
    func idleExitIsIgnored() {
        let probe = Probe()
        let first = makeWatch(probe)
        first.beginLaunch()
        first.enter(.transcribing, modelID: "parakeet-tdt-0.6b-v3")
        first.leave()

        #expect(makeWatch(probe).beginLaunch() == nil)
    }

    @Test("A clean exit is not reported even mid-work")
    func cleanExitIsIgnored() {
        let probe = Probe()
        let first = makeWatch(probe)
        first.beginLaunch()
        first.enter(.installing, modelID: "openai_whisper-small")
        first.markCleanExit()

        #expect(makeWatch(probe).beginLaunch() == nil)
    }

    @Test("during() returns to idle when the operation throws")
    func duringResetsOnThrow() async {
        struct Boom: Error {}
        let watch = makeWatch(Probe())
        watch.beginLaunch()
        await #expect(throws: Boom.self) {
            try await watch.during(.loading, modelID: "m") { throw Boom() }
        }
        #expect(watch.currentBreadcrumb.phase == .idle)
    }

    @Test("Background state and memory warnings are carried into the report")
    func backgroundAndWarningsRecorded() throws {
        let probe = Probe()
        let first = makeWatch(probe)
        first.beginLaunch()
        first.setInBackground(true)
        first.noteMemoryWarning()
        first.noteMemoryWarning()
        first.enter(.transcribing, modelID: "m")

        let exit = try #require(makeWatch(probe).beginLaunch())
        #expect(exit.breadcrumb.inBackground)
        #expect(exit.breadcrumb.memoryWarnings == 2)
        #expect(exit.summary.contains("in the background"))
    }

    @Test("A crash diagnostic covering the exit relabels it as a crash")
    func crashDiagnosticRelabels() throws {
        let probe = Probe()
        let first = makeWatch(probe)
        first.beginLaunch()
        first.enter(.loading, modelID: "m")
        let second = makeWatch(probe)
        let exit = try #require(second.beginLaunch())

        second.markCrash(between: exit.breadcrumb.updatedAt.addingTimeInterval(-60),
                         and: exit.breadcrumb.updatedAt.addingTimeInterval(60))

        let stored = try #require(second.recordedExits().first)
        #expect(stored.crashReported)
        #expect(stored.summary.hasPrefix("Crashed"))
    }

    @Test("resetPeak starts the peak over from the current footprint")
    func resetPeak() {
        let probe = Probe()
        let watch = makeWatch(probe)
        watch.beginLaunch()
        probe.setFootprint(2_000)
        watch.sample()
        probe.setFootprint(300)
        watch.resetPeak()
        #expect(watch.currentBreadcrumb.peakFootprintMB == 300)
    }
}
