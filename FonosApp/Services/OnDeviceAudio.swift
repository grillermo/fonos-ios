import AVFoundation
import Foundation

enum OnDeviceAudioError: LocalizedError {
    case conversionFailed

    var errorDescription: String? { "Could not convert the recording for the on-device model." }
}

/// Turns Fonos's 16-bit PCM WAV into the 16 kHz mono Float32 samples every
/// Dictus engine takes.
enum OnDeviceAudio {
    static let sampleRate: Double = 16_000

    static func samples(fromWAV data: Data) throws -> [Float] {
        let pcm = try AudioCaptureService.decodeWAV(data: data)
        if pcm.format.sampleRate == sampleRate, pcm.format.channelCount == 1,
           let channel = pcm.int16ChannelData?[0] {
            let count = Int(pcm.frameLength)
            return (0..<count).map { Float(channel[$0]) / 32_768 }
        }
        return try resample(pcm)
    }

    private static func resample(_ input: AVAudioPCMBuffer) throws -> [Float] {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: input.format, to: target) else {
            throw OnDeviceAudioError.conversionFailed
        }
        let ratio = sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw OnDeviceAudioError.conversionFailed
        }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0] else {
            throw OnDeviceAudioError.conversionFailed
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
