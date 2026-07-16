import AVFoundation
import Foundation
import os.log

extension AudioCaptureService {
    // MARK: - Private Helpers

    /// Reset bounded sample storage synchronously before the tap starts.
    nonisolated func resetSampleBuffer() {
        lock.lock()
        sampleBuffer = [Int16](repeating: 0, count: Self.maxSamples)
        totalSamplesWritten = 0
        lock.unlock()
    }

    func resetConversionResources() {
        converterLock.withLock {
            converter = nil
            converterOutputBuffer = nil
        }
    }

    func processTapBuffer(
        _ buffer: AVAudioPCMBuffer,
        token: AudioCaptureStartToken
    ) {
        // AVAudioEngine may deliver a callback already in flight while a tap is
        // being removed. Bind every tap to its start token so stale audio can
        // neither contaminate nor finalize a replacement capture.
        guard lifecycleLock.withLock({ activeCapture?.token == token }) else { return }
        Self.tapCallCount += 1
        let callNum = Self.tapCallCount

        // Log first few calls to verify tap is working
        if callNum <= 3 {
            let frames = buffer.frameLength
            let sampleRate = buffer.format.sampleRate
            let channels = buffer.format.channelCount
            audioCaptureLog.info("🔊 processTapBuffer #\(callNum): frames=\(frames), rate=\(sampleRate), channels=\(channels)")
        }

        // Compute audio level directly from the input buffer (float32 format)
        // This avoids needing the converter for visualization
        if let floatData = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            var sumOfSquares: Float = 0
            for i in 0..<frameLength {
                let sample = floatData[0][i]
                sumOfSquares += sample * sample
            }
            let rms = sqrt(sumOfSquares / max(1, Float(frameLength)))
            // Write level directly — no dispatch, no callback, no cross-thread publishing
            currentAudioLevel = min(1.0, rms * 5.0)
        }

        // Converter creation and buffer allocation are intentionally reused
        // across tap callbacks. The audio render path should not allocate two
        // heavyweight AVFoundation objects for every ~90 ms input buffer.
        converterLock.lock()
        defer { converterLock.unlock() }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
            converterOutputBuffer = nil
        }
        guard let converter else {
            if callNum <= 3 { audioCaptureLog.error("❌ Failed to create converter") }
            return
        }

        let ratio = captureFormat.sampleRate / buffer.format.sampleRate
        let requiredFrames = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * ratio) + 32
        )
        if converterOutputBuffer?.frameCapacity ?? 0 < requiredFrames {
            converterOutputBuffer = AVAudioPCMBuffer(
                pcmFormat: captureFormat,
                frameCapacity: requiredFrames
            )
        }
        guard let outputBuffer = converterOutputBuffer else {
            if callNum <= 3 { audioCaptureLog.error("❌ Failed to create output buffer") }
            return
        }
        outputBuffer.frameLength = 0

        let input = AudioCaptureConverterInput(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            input.next(status: outStatus)
        }

        if callNum <= 3 {
            let statusValue = status.rawValue
            let outputFrames = outputBuffer.frameLength
            let errorDescription = conversionError?.localizedDescription ?? "none"
            audioCaptureLog.info("🔊 Conversion #\(callNum): status=\(statusValue), outFrames=\(outputFrames), error=\(errorDescription)")
        }

        guard status != .error, let int16Ptr = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)

        lock.lock()
        let accepted = AudioCapturePolicy.acceptedSampleCount(
            currentCount: totalSamplesWritten,
            incomingCount: frameLength
        )
        if accepted > 0 {
            for index in 0..<accepted {
                sampleBuffer[totalSamplesWritten + index] = int16Ptr[0][index]
            }
            totalSamplesWritten += accepted
        }
        let reachedMaximumDuration = totalSamplesWritten >= Self.maxSamples
        lock.unlock()

        if reachedMaximumDuration {
            requestMaximumDurationFinish(token: token)
        }
    }

    /// Build a PCM buffer from the complete, prefix-preserving capture.
    func buildPCMBuffer() -> AVAudioPCMBuffer? {
        lock.lock()
        let sampleCount = min(totalSamplesWritten, Self.maxSamples)
        let capturedSamples = sampleBuffer
        lock.unlock()

        guard sampleCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        guard let int16Ptr = buffer.int16ChannelData else { return nil }

        for index in 0..<sampleCount {
            int16Ptr[0][index] = capturedSamples[index]
        }

        return buffer
    }

    // MARK: - Interruption Handling
}
