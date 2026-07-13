import Foundation
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.fonos.ios", category: "AudioCapture")

private final class AudioCaptureConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var wasProvided = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        guard !wasProvided else {
            status.pointee = .noDataNow
            return nil
        }
        wasProvided = true
        status.pointee = .haveData
        return buffer
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case engineStartFailed(Error)
    case sessionSetupFailed(Error)
    case permissionDenied
    case noInputAvailable
    case notRecording
    case captureAlreadyActive
    case startCancelled

    var errorDescription: String? {
        switch self {
        case .engineStartFailed(let err): return "Audio engine failed to start: \(err.localizedDescription)"
        case .sessionSetupFailed(let err): return "Audio session setup failed: \(err.localizedDescription)"
        case .permissionDenied: return "Microphone permission is required. Please enable it in Settings."
        case .noInputAvailable: return "No audio input available"
        case .notRecording: return "Not currently recording"
        case .captureAlreadyActive: return "Audio capture is already starting or recording"
        case .startCancelled: return "Audio capture start was cancelled"
        }
    }
}

enum WAVError: Error, LocalizedError {
    case invalidData
    case unsupportedFormat
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidData: return "WAV data is invalid or too short"
        case .unsupportedFormat: return "WAV format is not supported"
        case .bufferCreationFailed: return "Failed to create audio buffer from WAV data"
        }
    }
}

struct AudioCaptureStartToken: Hashable, Sendable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Narrow capture seam used by DictationViewModel. Tests can control the
/// asynchronous start completion without constructing AVAudioEngine hardware.
protocol AudioCapturing: AnyObject, Sendable {
    var currentAudioLevel: Float { get }
    var isRecording: Bool { get }
    var isStarting: Bool { get }
    func micPermissionStatus() -> AVAudioSession.RecordPermission
    func requestMicPermission() async -> Bool
    @discardableResult
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken
    @MainActor
    @discardableResult
    func stopCapture() -> Data?
}

extension AudioCapturing {
    @discardableResult
    func startCapture(
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken {
        startCapture(onInterruption: {}, completion: completion)
    }
}

// MARK: - AudioCaptureService

/// Records audio using AVAudioEngine and produces 16kHz 16-bit mono PCM buffers.
/// Stores up to 60 seconds of audio in a ring buffer.
///
/// Key design decisions:
/// - `captureFormat`, `isRecording`, `encodeToWAV`, and `decodeWAV` are intentionally
///   nonisolated so tests can call them synchronously without MainActor context.
/// - Internal state mutations happen on the main actor via DispatchQueue.main or Task.
final class AudioCaptureService: AudioCapturing, @unchecked Sendable {
    // MARK: - Public Properties

    /// The capture format: 16kHz, 16-bit integer PCM, mono.
    nonisolated let captureFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to create capture format")
        }
        return format
    }()

    /// True only after AVAudioEngine has really started.
    var isRecording: Bool {
        lifecycleLock.withLock {
            guard case .recording = activeCapture?.phase else { return false }
            return true
        }
    }

    /// True while asynchronous session/engine setup is still in flight.
    var isStarting: Bool {
        lifecycleLock.withLock {
            guard case .starting = activeCapture?.phase else { return false }
            return true
        }
    }

    /// Current audio level (0.0-1.0), written from audio thread. Read from main thread via polling.
    nonisolated(unsafe) private(set) var currentAudioLevel: Float = 0

    // MARK: - Private Properties

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let converterLock = NSLock()
    private let lifecycleLock = NSLock()
    private let captureQueue = DispatchQueue(
        label: "com.fonos.ios.audio-capture-lifecycle",
        qos: .userInitiated
    )

    private enum CapturePhase: Equatable {
        case starting
        case recording
    }

    private struct ActiveCapture {
        let token: AudioCaptureStartToken
        var phase: CapturePhase
        let onInterruption: @Sendable () -> Void
    }

    private var activeCapture: ActiveCapture?

    /// These flags are confined to `captureQueue` and make teardown
    /// idempotent across cancellation, setup failure, interruption and stop.
    private var inputTapInstalled = false
    private var audioSessionActive = false
    private var foregroundCapturePaused = false
    private var converter: AVAudioConverter?
    private var converterOutputBuffer: AVAudioPCMBuffer?

    /// Ring buffer storing raw Int16 PCM samples (16kHz mono = 16000 samples/sec)
    /// Max 60 seconds = 960_000 samples
    private static let maxSamples = 16_000 * 60
    private var ringBuffer: [Int16] = []
    private var ringWriteIndex = 0
    private var totalSamplesWritten = 0

    // MARK: - Init / Deinit

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Check current microphone permission status.
    nonisolated func micPermissionStatus() -> AVAudioSession.RecordPermission {
        // Keep the existing protocol type so capture test doubles remain simple,
        // while sourcing the permission from the iOS 17 API. Both enums use the
        // same four-character raw values for their three permission states.
        let rawValue = UInt(AVAudioApplication.shared.recordPermission.rawValue)
        guard let permission = AVAudioSession.RecordPermission(rawValue: rawValue) else {
            preconditionFailure("AVAudioApplication returned an unknown record-permission value")
        }
        return permission
    }

    /// Request microphone permission. Call only when status is .undetermined.
    func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Start audio capture. Must be called AFTER mic permission is granted.
    /// The token is committed to `.recording` only after `engine.start()`
    /// succeeds. `stopCapture()` invalidates it synchronously, so a queued
    /// setup can never resurrect capture after the user has stopped.
    @discardableResult
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void = {},
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken {
        let token = AudioCaptureStartToken()
        let accepted = lifecycleLock.withLock { () -> Bool in
            guard activeCapture == nil else { return false }
            activeCapture = ActiveCapture(
                token: token,
                phase: .starting,
                onInterruption: onInterruption
            )
            return true
        }
        guard accepted else {
            captureQueue.async {
                completion(AudioCaptureError.captureAlreadyActive)
            }
            return token
        }

        // This bridge may hop synchronously to MainActor. Do it before the
        // lifecycle queue starts so a MainActor stop can never deadlock while
        // waiting for a queue that is itself waiting for MainActor.
        BackgroundRecordingService.shared.pauseForForegroundCapture()
        captureQueue.async { [self] in
            foregroundCapturePaused = true
            _startCaptureSync(token: token, completion: completion)
        }
        return token
    }

    /// Internal synchronous engine setup, serialized with every teardown.
    private func _startCaptureSync(
        token: AudioCaptureStartToken,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        log.info("🎙 startCapture() on lifecycle queue")
        guard isCurrentStart(token) else {
            finishStart(token: token, error: .startCancelled, completion: completion)
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setPreferredSampleRate(16_000)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            audioSessionActive = true
        } catch {
            finishStart(
                token: token,
                error: .sessionSetupFailed(error),
                completion: completion
            )
            return
        }

        guard isCurrentStart(token) else {
            finishStart(token: token, error: .startCancelled, completion: completion)
            return
        }

        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if engine.isRunning { engine.stop() }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            finishStart(token: token, error: .noInputAvailable, completion: completion)
            return
        }

        resetRingBuffer()
        resetConversionResources()
        engine.prepare()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer)
        }
        inputTapInstalled = true

        guard isCurrentStart(token) else {
            finishStart(token: token, error: .startCancelled, completion: completion)
            return
        }

        do {
            try engine.start()
        } catch {
            finishStart(
                token: token,
                error: .engineStartFailed(error),
                completion: completion
            )
            return
        }

        guard commitStart(token) else {
            finishStart(token: token, error: .startCancelled, completion: completion)
            return
        }
        log.info("🎙 Recording started on lifecycle queue ✅")
        completion(nil)
    }

    /// Stop a real recording or cancel an in-flight start. Resource teardown
    /// is serialized after setup and remains idempotent if setup observes the
    /// cancellation first.
    @MainActor
    @discardableResult
    func stopCapture() -> Data? {
        let stoppedPhase = lifecycleLock.withLock { () -> CapturePhase? in
            guard let activeCapture else { return nil }
            self.activeCapture = nil
            return activeCapture.phase
        }
        guard let stoppedPhase else { return nil }

        let teardown = captureQueue.sync { [self] in
            teardownCaptureResources(
                buildWAV: stoppedPhase == .recording
            )
        }
        if teardown.shouldResumeKeyboardReady {
            BackgroundRecordingService.shared.resumeAfterForegroundCapture()
        }
        return teardown.wavData
    }

    private func isCurrentStart(_ token: AudioCaptureStartToken) -> Bool {
        lifecycleLock.withLock {
            guard let activeCapture,
                  activeCapture.token == token,
                  case .starting = activeCapture.phase else { return false }
            return true
        }
    }

    private func commitStart(_ token: AudioCaptureStartToken) -> Bool {
        lifecycleLock.withLock {
            guard var activeCapture,
                  activeCapture.token == token,
                  case .starting = activeCapture.phase else { return false }
            activeCapture.phase = .recording
            self.activeCapture = activeCapture
            return true
        }
    }

    private func clearStartIfCurrent(_ token: AudioCaptureStartToken) -> Bool {
        lifecycleLock.withLock {
            guard let activeCapture, activeCapture.token == token else { return false }
            self.activeCapture = nil
            return true
        }
    }

    private func finishStart(
        token: AudioCaptureStartToken,
        error: AudioCaptureError,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let wasCurrent = clearStartIfCurrent(token)
        let teardown = teardownCaptureResources(buildWAV: false)
        if teardown.shouldResumeKeyboardReady {
            DispatchQueue.main.async {
                BackgroundRecordingService.shared.resumeAfterForegroundCapture()
            }
        }
        completion(wasCurrent ? error : AudioCaptureError.startCancelled)
    }

    private func teardownCaptureResources(
        buildWAV: Bool
    ) -> (wavData: Data?, shouldResumeKeyboardReady: Bool) {
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        currentAudioLevel = 0
        resetConversionResources()

        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            audioSessionActive = false
        }

        let wavData: Data?
        if buildWAV, let buffer = buildPCMBuffer() {
            wavData = try? Self.encodeToWAV(buffer: buffer)
        } else {
            wavData = nil
        }

        let shouldResume = foregroundCapturePaused
        foregroundCapturePaused = false
        return (wavData, shouldResume)
    }

    // MARK: - Private Helpers

    /// Reset ring buffer state. Called synchronously (not in async context) to avoid NSLock warnings.
    private nonisolated func resetRingBuffer() {
        lock.lock()
        ringBuffer = [Int16](repeating: 0, count: Self.maxSamples)
        ringWriteIndex = 0
        totalSamplesWritten = 0
        lock.unlock()
    }

    private func resetConversionResources() {
        converterLock.withLock {
            converter = nil
            converterOutputBuffer = nil
        }
    }

    private nonisolated(unsafe) static var tapCallCount = 0

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        Self.tapCallCount += 1
        let callNum = Self.tapCallCount

        // Log first few calls to verify tap is working
        if callNum <= 3 {
            let frames = buffer.frameLength
            let sampleRate = buffer.format.sampleRate
            let channels = buffer.format.channelCount
            log.info("🔊 processTapBuffer #\(callNum): frames=\(frames), rate=\(sampleRate), channels=\(channels)")
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
            if callNum <= 3 { log.error("❌ Failed to create converter") }
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
            if callNum <= 3 { log.error("❌ Failed to create output buffer") }
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
            log.info("🔊 Conversion #\(callNum): status=\(statusValue), outFrames=\(outputFrames), error=\(errorDescription)")
        }

        guard status != .error, let int16Ptr = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)

        lock.lock()
        for i in 0..<frameLength {
            ringBuffer[ringWriteIndex] = int16Ptr[0][i]
            ringWriteIndex = (ringWriteIndex + 1) % Self.maxSamples
            totalSamplesWritten += 1
        }
        lock.unlock()
    }

    /// Build a PCM buffer from the ring buffer contents.
    private func buildPCMBuffer() -> AVAudioPCMBuffer? {
        lock.lock()
        let sampleCount = min(totalSamplesWritten, Self.maxSamples)
        let capturedRingBuffer = ringBuffer
        let capturedWriteIndex = ringWriteIndex
        let capturedTotal = totalSamplesWritten
        lock.unlock()

        guard sampleCount > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        guard let int16Ptr = buffer.int16ChannelData else { return nil }

        if capturedTotal <= Self.maxSamples {
            for i in 0..<sampleCount {
                int16Ptr[0][i] = capturedRingBuffer[i]
            }
        } else {
            for i in 0..<sampleCount {
                let srcIndex = (capturedWriteIndex + i) % Self.maxSamples
                int16Ptr[0][i] = capturedRingBuffer[srcIndex]
            }
        }

        return buffer
    }

    // MARK: - Interruption Handling

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .began else { return }

        Task { @MainActor in
            let interruptionHandler = self.lifecycleLock.withLock {
                self.activeCapture?.onInterruption
            }
            guard let interruptionHandler else { return }
            _ = self.stopCapture()
            interruptionHandler()
        }
    }
}
