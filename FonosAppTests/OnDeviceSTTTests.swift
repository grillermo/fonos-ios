import Foundation
import Testing
@testable import FonosApp

struct OnDeviceSTTTests {
    /// A 16-bit mono PCM WAV with the given samples.
    private func wav(_ samples: [Int16], sampleRate: UInt32 = 16_000) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(sampleRate)
        append(sampleRate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        samples.forEach { append($0) }
        return data
    }

    @Test("16 kHz WAV converts to Float samples in -1...1")
    func convertsWAV() throws {
        let samples = try OnDeviceAudio.samples(fromWAV: wav([0, 16_384, -32_768]))
        #expect(samples == [0, 0.5, -1])
    }

    @Test("48 kHz WAV is resampled to 16 kHz")
    func resamples() throws {
        let samples = try OnDeviceAudio.samples(fromWAV: wav(Array(repeating: 1_000, count: 4_800), sampleRate: 48_000))
        #expect(abs(samples.count - 1_600) <= 32)
    }

    @Test("An on-device profile resolves to OnDeviceSTT with its model")
    func resolverPicksOnDevice() throws {
        var config = AppConfig()
        let profile = ModelProfile.onDevice(modelID: "openai_whisper-small", displayName: "Small")
        config.modelProfiles = [profile]
        config.sttProfile = profile.id

        let provider = try #require(STTResolver.resolve(config: config) as? OnDeviceSTT)
        #expect(provider.modelID == "openai_whisper-small")
        #expect(profile.id == "ondevice-openai_whisper-small")
        #expect(profile.hasSTT && !profile.hasLLM)
    }

    @Test("Run log keeps newest first and finds a model's latest run")
    func runLog() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runs-\(UUID().uuidString).json")
        let log = OnDeviceRunLog(url: url)
        func run(_ id: String, _ ms: Int) -> OnDeviceRun {
            OnDeviceRun(modelID: id, finishedAt: Date(), audioSeconds: 10,
                        loadMilliseconds: 0, transcribeMilliseconds: ms,
                        peakFootprintMB: 500, characters: 42)
        }
        log.append(run("a", 1_000))
        log.append(run("b", 2_000))
        log.append(run("a", 500))

        #expect(log.runs().map(\.modelID) == ["a", "b", "a"])
        #expect(log.latest(for: "a")?.realTimeFactor == 20)
    }

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
