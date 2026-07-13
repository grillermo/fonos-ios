import AVFoundation
import Foundation

extension AudioCaptureService {
    /// Encode an AVAudioPCMBuffer (must be Int16 PCM) to WAV Data.
    nonisolated static func encodeToWAV(buffer: AVAudioPCMBuffer) throws -> Data {
        let format = buffer.format
        let sampleRate = UInt32(format.sampleRate)
        let channelCount = UInt16(format.channelCount)
        let bitsPerSample: UInt16 = 16
        let frameCount = Int(buffer.frameLength)

        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataSize = UInt32(frameCount) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))

        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(chunkSize)
        data.append(contentsOf: "WAVE".utf8)

        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)

        if let int16Data = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<Int(channelCount) {
                    data.appendLittleEndian(int16Data[channel][frame])
                }
            }
        } else if let floatData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<Int(channelCount) {
                    let clamped = max(-1.0, min(1.0, floatData[channel][frame]))
                    data.appendLittleEndian(Int16(clamped * Float(Int16.max)))
                }
            }
        }

        return data
    }

    /// Decode WAV data back to AVAudioPCMBuffer.
    nonisolated static func decodeWAV(data: Data) throws -> AVAudioPCMBuffer {
        guard data.count >= 44 else { throw WAVError.invalidData }
        guard String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE",
              String(bytes: data[12..<16], encoding: .ascii) == "fmt " else {
            throw WAVError.invalidData
        }

        let audioFormat = data.readLittleEndian(UInt16.self, at: 20)
        let channelCount = data.readLittleEndian(UInt16.self, at: 22)
        let sampleRate = data.readLittleEndian(UInt32.self, at: 24)
        let bitsPerSample = data.readLittleEndian(UInt16.self, at: 34)

        guard audioFormat == 1, bitsPerSample == 16 else {
            throw WAVError.unsupportedFormat
        }
        guard channelCount > 0, sampleRate > 0 else {
            throw WAVError.invalidData
        }

        let dataChunk = findDataChunk(in: data)
        guard dataChunk.size > 0, dataChunk.offset > 0 else {
            throw WAVError.invalidData
        }

        let bytesPerSample = Int(bitsPerSample / 8)
        let bytesPerFrame = Int(channelCount) * bytesPerSample
        let pcmByteCount = Int(dataChunk.size)
        guard pcmByteCount <= data.count - dataChunk.offset,
              pcmByteCount.isMultiple(of: bytesPerFrame) else {
            throw WAVError.invalidData
        }
        let frameCount = pcmByteCount / bytesPerFrame
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw WAVError.unsupportedFormat
        }
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw WAVError.bufferCreationFailed
        }
        outputBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let int16Data = outputBuffer.int16ChannelData else {
            throw WAVError.bufferCreationFailed
        }

        var byteOffset = dataChunk.offset
        for frame in 0..<frameCount {
            for channel in 0..<Int(channelCount) {
                guard byteOffset + 2 <= data.count else { break }
                int16Data[channel][frame] = data.readLittleEndian(Int16.self, at: byteOffset)
                byteOffset += 2
            }
        }

        return outputBuffer
    }

    private nonisolated static func findDataChunk(in data: Data) -> (offset: Int, size: UInt32) {
        var searchOffset = 36
        while searchOffset + 8 <= data.count {
            let identifier = String(
                bytes: data[searchOffset..<(searchOffset + 4)],
                encoding: .ascii
            )
            let size = data.readLittleEndian(UInt32.self, at: searchOffset + 4)
            if identifier == "data" {
                return (searchOffset + 8, size)
            }
            // RIFF chunks are word-aligned: odd payload sizes have one pad byte.
            searchOffset += 8 + Int(size) + Int(size % 2)
        }
        return (0, 0)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Int16) {
        appendLittleEndian(UInt16(bitPattern: value))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        guard offset + MemoryLayout<T>.size <= count else { return 0 }
        return subdata(in: offset..<(offset + MemoryLayout<T>.size)).withUnsafeBytes {
            $0.loadUnaligned(as: T.self).littleEndian
        }
    }
}
