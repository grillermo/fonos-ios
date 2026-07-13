import Foundation

/// Pure helpers for wrapping the keyboard bridge's bounded 16-bit PCM buffer
/// as WAV and inspecting the resulting payload.
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
