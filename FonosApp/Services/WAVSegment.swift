import Foundation

/// Pure WAV byte-slicing used by the keyboard's continuous recorder to cut a
/// segment out of the always-running `kb_continuous.wav` file.
///
/// The file is read WHILE AVAudioRecorder is still recording (it is never
/// stopped, to keep audio alive in the background). That has one sharp edge:
/// AVAudioRecorder leaves the `data` chunk's size field at 0 until `stop()`
/// finalizes the header, so the declared size cannot be trusted for a live
/// file — the real PCM runs from the start of the `data` chunk to the current
/// end of the file.
enum WAVSegment {

    /// Byte range of the PCM payload (the `data` chunk body) within `data`.
    static func pcmRange(in data: Data) -> Range<Int> {
        let fallbackHeaderSize = min(44, data.count)
        guard data.count >= 12 else { return fallbackHeaderSize..<data.count }

        var cursor = 12
        while cursor + 8 <= data.count {
            let chunkID = String(data: data[cursor..<cursor + 4], encoding: .ascii)
            let sizeStart = cursor + 4
            let chunkSize = UInt32(data[sizeStart])
                | (UInt32(data[sizeStart + 1]) << 8)
                | (UInt32(data[sizeStart + 2]) << 16)
                | (UInt32(data[sizeStart + 3]) << 24)
            let dataStart = cursor + 8
            if chunkID == "data" {
                // AVAudioRecorder writes size 0 until stop() finalizes the header,
                // so a declared 0 (or a size that would truncate an already-longer
                // file) means "read to the current end of the growing file".
                let declaredEnd = dataStart + Int(chunkSize)
                let dataEnd = (chunkSize > 0 && declaredEnd <= data.count) ? declaredEnd : data.count
                return dataStart..<dataEnd
            }
            cursor = dataStart + Int(chunkSize)
            if cursor % 2 == 1 { cursor += 1 }
        }

        return fallbackHeaderSize..<data.count
    }

    /// Cut `[startTime, endTime]` (seconds) out of the PCM and re-wrap as WAV.
    static func segment(_ data: Data, from startTime: TimeInterval, to endTime: TimeInterval,
                        sampleRate: Int) -> Data {
        let bytesPerSample = 2  // 16-bit mono
        let dataRange = pcmRange(in: data)
        let bytesPerSecond = sampleRate * bytesPerSample

        let startByte = dataRange.lowerBound + Int(startTime * Double(bytesPerSecond))
        let endByte = min(dataRange.upperBound, dataRange.lowerBound + Int(endTime * Double(bytesPerSecond)))

        guard startByte < endByte, startByte < dataRange.upperBound else { return Data() }
        return build(from: data[startByte..<endByte], sampleRate: sampleRate)
    }

    /// Take the last `duration` seconds of PCM and re-wrap as WAV.
    static func tail(_ data: Data, duration: TimeInterval, sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataRange = pcmRange(in: data)
        guard !dataRange.isEmpty else { return Data() }

        let bytesPerSecond = sampleRate * bytesPerSample
        let availablePCMBytes = dataRange.count
        let requestedBytes = max(bytesPerSample, Int(duration * Double(bytesPerSecond)))
        let pcmByteCount = min(availablePCMBytes, requestedBytes)
        let startByte = dataRange.upperBound - pcmByteCount
        return build(from: data[startByte..<dataRange.upperBound], sampleRate: sampleRate)
    }

    /// Wrap raw 16-bit mono PCM in a minimal valid WAV header.
    static func build(from pcmData: Data.SubSequence, sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = UInt32(pcmData.count)

        var wav = Data(capacity: 44 + Int(dataSize))
        func u16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: "RIFF".utf8); u32(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * bytesPerSample)); u16(UInt16(bytesPerSample)); u16(16)
        wav.append(contentsOf: "data".utf8); u32(dataSize)
        wav.append(pcmData)
        return wav
    }
}
