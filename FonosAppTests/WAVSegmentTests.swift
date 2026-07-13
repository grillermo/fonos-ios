// Covers the in-memory Keyboard Ready PCM wrapper and robust WAV inspection.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/WAVSegmentTests

import Testing
import Foundation
@testable import FonosApp

private func u32le(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
}
private func u16le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

private func fmtChunk(sampleRate: Int = 16000) -> [UInt8] {
    var b: [UInt8] = Array("fmt ".utf8)
    b += u32le(16)
    b += u16le(1)                                   // PCM
    b += u16le(1)                                   // mono
    b += u32le(UInt32(sampleRate))
    b += u32le(UInt32(sampleRate * 2))
    b += u16le(2)                                   // block align
    b += u16le(16)                                  // bits
    return b
}

/// A WAV whose `data` chunk declares `declaredDataSize` but is followed by
/// `pcmBytes` actual bytes — the live-recording shape when declaredDataSize=0.
private func wav(declaredDataSize: UInt32, pcmBytes: Int,
                 extraChunkBeforeData: [UInt8] = []) -> Data {
    wav(declaredDataSize: declaredDataSize,
        pcm: [UInt8](repeating: 0x11, count: pcmBytes),
        extraChunkBeforeData: extraChunkBeforeData)
}

private func wav(declaredDataSize: UInt32, pcm: [UInt8],
                 extraChunkBeforeData: [UInt8] = []) -> Data {
    var body: [UInt8] = []
    body += Array("WAVE".utf8)
    body += fmtChunk()
    body += extraChunkBeforeData
    body += Array("data".utf8)
    body += u32le(declaredDataSize)

    var out: [UInt8] = Array("RIFF".utf8)
    out += u32le(UInt32(4 + body.count + pcm.count))
    out += body
    out += pcm
    return Data(out)
}

struct WAVSegmentTests {

    @Test("in-memory keyboard PCM is wrapped as a valid 16 kHz mono WAV")
    func inMemoryPCMBuildsValidWAV() {
        let pcm = Data(repeating: 0x22, count: 32_000)
        let output = WAVSegment.build(
            from: pcm[pcm.startIndex..<pcm.endIndex],
            sampleRate: 16_000
        )

        #expect(String(data: output[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: output[8..<12], encoding: .ascii) == "WAVE")
        #expect(WAVSegment.pcmByteCount(in: output) == 32_000)
        #expect(WAVSegment.duration(of: output, sampleRate: 16_000) == 1)
    }

    // MARK: - The regression

    @Test("live recording (declared data size 0) exposes all appended PCM")
    func liveRecordingUsesFileEnd() {
        let data = wav(declaredDataSize: 0, pcmBytes: 8000)   // 0.25s @ 16kHz mono
        let range = WAVSegment.pcmRange(in: data)
        // data chunk header ends at offset 44 for a standard header.
        #expect(range.lowerBound == 44)
        #expect(range.count == 8000)
    }

    // MARK: - Header robustness

    @Test("PCM start is found past a non-standard header chunk")
    func findsDataPastExtraChunk() {
        // A 4-byte FLLR filler chunk before data shifts dataStart by 12 bytes.
        var fllr: [UInt8] = Array("FLLR".utf8)
        fllr += u32le(4)
        fllr += [0, 0, 0, 0]
        let data = wav(declaredDataSize: 0, pcmBytes: 6000, extraChunkBeforeData: fllr)
        let range = WAVSegment.pcmRange(in: data)
        #expect(range.lowerBound == 44 + 12)   // extra 12-byte chunk
        #expect(range.count == 6000)
    }

    // MARK: - Finalized files still respected

    @Test("finalized file with a correct data size uses that size")
    func finalizedUsesDeclaredSize() {
        // Declared size smaller than the file (e.g. trailing chunk): respect it.
        var data = wav(declaredDataSize: 4000, pcmBytes: 4000)
        data.append(contentsOf: Array("LIST".utf8) + u32le(4) + [1, 2, 3, 4]) // trailing chunk
        let range = WAVSegment.pcmRange(in: data)
        #expect(range.count == 4000)
    }
}
