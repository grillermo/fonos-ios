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
    private static let bytesPerSample = 2  // 16-bit mono

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

    /// Number of complete PCM bytes currently available in the WAV payload.
    static func pcmByteCount(in data: Data) -> Int {
        alignDownToSample(pcmRange(in: data).count)
    }

    /// Cut `[startTime, endTime]` (seconds) out of the PCM and re-wrap as WAV.
    static func segment(_ data: Data, from startTime: TimeInterval, to endTime: TimeInterval,
                        sampleRate: Int) -> Data {
        let bytesPerSecond = sampleRate * bytesPerSample

        let startOffset = Int(startTime * Double(bytesPerSecond))
        let endOffset = Int(endTime * Double(bytesPerSecond))
        return segment(data, fromPCMByteOffset: startOffset, toPCMByteOffset: endOffset, sampleRate: sampleRate)
    }

    /// Cut a PCM byte range out of the WAV payload and re-wrap as WAV.
    ///
    /// Offsets are relative to the start of the `data` chunk body.
    static func segment(_ data: Data, fromPCMByteOffset startOffset: Int, toPCMByteOffset endOffset: Int,
                        sampleRate: Int) -> Data {
        let dataRange = pcmRange(in: data)
        let availablePCMBytes = alignDownToSample(dataRange.count)
        guard availablePCMBytes > 0 else { return Data() }

        let startOffset = min(max(0, alignDownToSample(startOffset)), availablePCMBytes)
        let endOffset = min(max(0, alignDownToSample(endOffset)), availablePCMBytes)
        guard startOffset < endOffset else { return Data() }

        let startByte = dataRange.lowerBound + startOffset
        let endByte = dataRange.lowerBound + endOffset
        return build(from: data[startByte..<endByte], sampleRate: sampleRate)
    }

    /// Take the last `duration` seconds of PCM and re-wrap as WAV.
    static func tail(_ data: Data, duration: TimeInterval, sampleRate: Int) -> Data {
        let dataRange = pcmRange(in: data)
        guard !dataRange.isEmpty else { return Data() }

        let bytesPerSecond = sampleRate * bytesPerSample
        let availablePCMBytes = alignDownToSample(dataRange.count)
        let requestedBytes = alignDownToSample(max(bytesPerSample, Int(duration * Double(bytesPerSecond))))
        let pcmByteCount = min(availablePCMBytes, requestedBytes)
        let endByte = dataRange.lowerBound + availablePCMBytes
        let startByte = endByte - pcmByteCount
        return build(from: data[startByte..<endByte], sampleRate: sampleRate)
    }

    /// Wrap raw 16-bit mono PCM in a minimal valid WAV header.
    static func build(from pcmData: Data.SubSequence, sampleRate: Int) -> Data {
        let alignedCount = alignDownToSample(pcmData.count)
        let dataSize = UInt32(alignedCount)
        let alignedEnd = pcmData.startIndex + alignedCount

        var wav = Data(capacity: 44 + Int(dataSize))
        func u16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: "RIFF".utf8); u32(36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * bytesPerSample)); u16(UInt16(bytesPerSample)); u16(16)
        wav.append(contentsOf: "data".utf8); u32(dataSize)
        wav.append(pcmData[pcmData.startIndex..<alignedEnd])
        return wav
    }

    static func duration(of wavData: Data, sampleRate: Int) -> TimeInterval {
        Double(pcmByteCount(in: wavData)) / Double(sampleRate * bytesPerSample)
    }

    private static func alignDownToSample(_ byteCount: Int) -> Int {
        max(0, byteCount - (byteCount % bytesPerSample))
    }
}
