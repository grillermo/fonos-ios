// INV-02: AudioCaptureService opens mic, records, produces valid PCM buffer
// (16kHz, 16-bit, mono, non-zero samples). WAV encoding produces valid file.
//
// Verifier: auto
// Level: unit (AVAudioEngine mocked via dependency injection)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/INV02AudioCaptureTests

import Testing
import AVFoundation
@testable import FonosApp

// MARK: - Helpers

/// A minimal mock audio buffer with known sample data.
private func makeMockPCMBuffer(sampleRate: Double = 16_000,
                               channelCount: AVAudioChannelCount = 1,
                               frameCount: AVAudioFrameCount = 1_600) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                               sampleRate: sampleRate,
                               channels: channelCount,
                               interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    // Fill with a simple 440 Hz sine wave so samples are non-zero
    if let int16ChannelData = buffer.int16ChannelData {
        for i in 0..<Int(frameCount) {
            let phase = Double(i) / sampleRate * 440.0 * 2.0 * .pi
            int16ChannelData[0][i] = Int16(sin(phase) * Double(Int16.max))
        }
    }
    return buffer
}

// MARK: - Tests

struct INV02AudioCaptureTests {

    // --- Format ---

    @Test("AudioCaptureService output format is 16kHz")
    func outputSampleRate() throws {
        let service = AudioCaptureService()
        let format = service.captureFormat
        #expect(format.sampleRate == 16_000)
    }

    @Test("AudioCaptureService output format is mono (1 channel)")
    func outputChannelCount() throws {
        let service = AudioCaptureService()
        let format = service.captureFormat
        #expect(format.channelCount == 1)
    }

    @Test("AudioCaptureService output format is 16-bit integer PCM")
    func outputBitDepth() throws {
        let service = AudioCaptureService()
        let format = service.captureFormat
        #expect(format.commonFormat == .pcmFormatInt16)
    }

    // --- WAV header validation ---

    @Test("WAV encoder produces RIFF header chunk")
    func wavHasRIFFChunk() throws {
        let buffer = makeMockPCMBuffer()
        let wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        // First 4 bytes must be "RIFF"
        let riff = String(bytes: wavData.prefix(4), encoding: .ascii)
        #expect(riff == "RIFF")
    }

    @Test("WAV encoder produces WAVE format identifier")
    func wavHasWAVEIdentifier() throws {
        let buffer = makeMockPCMBuffer()
        let wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        // Bytes 8-11 must be "WAVE"
        let wave = String(bytes: wavData[8..<12], encoding: .ascii)
        #expect(wave == "WAVE")
    }

    @Test("WAV encoder produces fmt chunk")
    func wavHasFmtChunk() throws {
        let buffer = makeMockPCMBuffer()
        let wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        // Bytes 12-15 must be "fmt "
        let fmt = String(bytes: wavData[12..<16], encoding: .ascii)
        #expect(fmt == "fmt ")
    }

    @Test("WAV encoder produces data chunk")
    func wavHasDataChunk() throws {
        let buffer = makeMockPCMBuffer()
        let wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        // "data" chunk must appear somewhere after the fmt chunk
        let dataBytes = Array(wavData)
        let dataChunkHeader = Array("data".utf8)
        let found = dataBytes.windows(ofCount: 4).contains { Array($0) == dataChunkHeader }
        #expect(found)
    }

    @Test("WAV encoder total size equals 44-byte header + PCM payload")
    func wavCorrectTotalSize() throws {
        let frameCount: AVAudioFrameCount = 1_600
        let buffer = makeMockPCMBuffer(frameCount: frameCount)
        let wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        let expectedSize = 44 + Int(frameCount) * 2 // 16-bit = 2 bytes per sample, mono
        #expect(wavData.count == expectedSize)
    }

    // --- Sample count round-trip ---

    @Test("WAV encode → decode preserves sample count")
    func wavRoundTripSampleCount() throws {
        let originalFrameCount: AVAudioFrameCount = 3_200
        let original = makeMockPCMBuffer(frameCount: originalFrameCount)
        let wavData = try AudioCaptureService.encodeToWAV(buffer: original)
        let decoded = try AudioCaptureService.decodeWAV(data: wavData)
        #expect(decoded.frameLength == originalFrameCount)
    }

    @Test("WAV encode → decode preserves non-zero sample values")
    func wavRoundTripSampleValues() throws {
        let buffer = makeMockPCMBuffer(frameCount: 160)
        let wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        let decoded = try AudioCaptureService.decodeWAV(data: wavData)
        // At least one sample must be non-zero
        if let ch = decoded.int16ChannelData {
            let hasNonZero = (0..<Int(decoded.frameLength)).contains { ch[0][$0] != 0 }
            #expect(hasNonZero)
        } else {
            Issue.record("Decoded buffer has no int16 channel data")
        }
    }

    @Test("WAV decoder rejects a zero-channel header without crashing")
    func wavRejectsZeroChannels() throws {
        let buffer = makeMockPCMBuffer(frameCount: 160)
        var wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        wavData[22] = 0
        wavData[23] = 0

        #expect(throws: WAVError.self) {
            _ = try AudioCaptureService.decodeWAV(data: wavData)
        }
    }

    @Test("WAV decoder rejects a data chunk larger than its payload")
    func wavRejectsTruncatedPayload() throws {
        let buffer = makeMockPCMBuffer(frameCount: 160)
        var wavData = try AudioCaptureService.encodeToWAV(buffer: buffer)
        wavData[40] = 0xff
        wavData[41] = 0xff
        wavData[42] = 0xff
        wavData[43] = 0x7f

        #expect(throws: WAVError.self) {
            _ = try AudioCaptureService.decodeWAV(data: wavData)
        }
    }

    // --- M4A upload encoding ---

    @Test("M4A encoder produces an MP4 container")
    func m4aEncoderProducesMP4Container() throws {
        let wavData = try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer(frameCount: 32_000))
        let m4aData = try AudioCaptureService.encodeToM4A(wavData: wavData)
        #expect(m4aData.count > 8)
        #expect(String(bytes: m4aData[4..<8], encoding: .ascii) == "ftyp")
    }

    @Test("M4A encoder output is far smaller than the WAV")
    func m4aEncoderCompresses() throws {
        let wavData = try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer(frameCount: 160_000))
        let m4aData = try AudioCaptureService.encodeToM4A(wavData: wavData)
        // 10 s WAV is 320 KB; the m4a is ~40 KB including ~24 KB of fixed container overhead.
        #expect(m4aData.count * 4 < wavData.count)
    }

    @Test("M4A encode keeps the recording's duration")
    func m4aEncoderKeepsDuration() throws {
        let wavData = try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer(frameCount: 32_000))
        let m4aData = try AudioCaptureService.encodeToM4A(wavData: wavData)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv02-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try m4aData.write(to: url)

        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        #expect(abs(seconds - 2.0) < 0.1)
        #expect(file.fileFormat.channelCount == 1)
    }

    @Test("M4A encoder rejects a WAV with no samples")
    func m4aEncoderRejectsEmptyWAV() throws {
        // Header only: the samples the header promises are missing.
        let wavData = Data(try AudioCaptureService.encodeToWAV(buffer: makeMockPCMBuffer()).prefix(44))
        #expect(throws: WAVError.invalidData) {
            _ = try AudioCaptureService.encodeToM4A(wavData: wavData)
        }
    }

    // --- Service lifecycle ---

    @Test("AudioCaptureService is not recording immediately after init")
    func notRecordingAfterInit() throws {
        let service = AudioCaptureService()
        #expect(service.isRecording == false)
    }
}

// MARK: - Sequence windows helper (stdlib backfill for older SDKs)

private extension Array {
    func windows(ofCount size: Int) -> [[Element]] {
        guard size > 0, size <= count else { return [] }
        return (0...(count - size)).map { Array(self[$0..<($0 + size)]) }
    }
}
