// The keyboard's continuous recorder reads kb_continuous.wav WHILE
// AVAudioRecorder is still recording. AVAudioRecorder leaves the data-chunk
// size at 0 until stop(), so the extractor must use the real file bytes, not
// the declared size — otherwise a live recording extracts to nothing and the
// keyboard shows "No audio captured."
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
    var body: [UInt8] = []
    body += Array("WAVE".utf8)
    body += fmtChunk()
    body += extraChunkBeforeData
    body += Array("data".utf8)
    body += u32le(declaredDataSize)
    let pcm = [UInt8](repeating: 0x11, count: pcmBytes)

    var out: [UInt8] = Array("RIFF".utf8)
    out += u32le(UInt32(4 + body.count + pcm.count))
    out += body
    out += pcm
    return Data(out)
}

struct WAVSegmentTests {

    // MARK: - The regression

    @Test("live recording (declared data size 0) exposes all appended PCM")
    func liveRecordingUsesFileEnd() {
        let data = wav(declaredDataSize: 0, pcmBytes: 8000)   // 0.25s @ 16kHz mono
        let range = WAVSegment.pcmRange(in: data)
        // data chunk header ends at offset 44 for a standard header.
        #expect(range.lowerBound == 44)
        #expect(range.count == 8000)
    }

    @Test("segment of a live recording returns the requested audio, not empty")
    func liveSegmentNotEmpty() {
        let data = wav(declaredDataSize: 0, pcmBytes: 32000)   // 1.0s
        let seg = WAVSegment.segment(data, from: 0, to: 0.5, sampleRate: 16000)
        #expect(seg.count > 100)
        // 0.5s of 16-bit mono @16kHz = 16000 bytes PCM + 44 header.
        #expect(seg.count == 44 + 16000)
    }

    @Test("tail of a live recording returns the requested audio, not empty")
    func liveTailNotEmpty() {
        let data = wav(declaredDataSize: 0, pcmBytes: 32000)
        let tail = WAVSegment.tail(data, duration: 0.5, sampleRate: 16000)
        #expect(tail.count > 100)
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
