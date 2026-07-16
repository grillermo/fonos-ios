import AVFoundation
import Foundation
import os.log

extension AudioCaptureService {
    /// Start audio capture. Must be called AFTER mic permission is granted.
    /// The token is committed to `.recording` only after `engine.start()`
    /// succeeds. `stopCapture()` invalidates it synchronously, so a queued
    /// setup can never resurrect capture after the user has stopped.
    @discardableResult
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void = {},
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken {
        let token = AudioCaptureStartToken()
        guard ForegroundAudioCaptureLeaseRegistry.shared.acquire(token) else {
            captureQueue.async {
                completion(AudioCaptureError.captureAlreadyActive)
            }
            return token
        }
        let accepted = lifecycleLock.withLock { () -> Bool in
            guard activeCapture == nil else { return false }
            automaticallyFinalizedWAV = nil
            automaticallyFinalizedResultAvailable = false
            activeCapture = ActiveCapture(
                token: token,
                phase: .starting,
                onInterruption: onInterruption,
                onMaximumDurationReached: onMaximumDurationReached
            )
            return true
        }
        guard accepted else {
            ForegroundAudioCaptureLeaseRegistry.shared.release(token)
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
    func _startCaptureSync(
        token: AudioCaptureStartToken,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        audioCaptureLog.info("🎙 startCapture() on lifecycle queue")
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

        resetSampleBuffer()
        resetConversionResources()
        engine.prepare()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer, token: token)
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
        scheduleMaximumDurationWatchdog(for: token)
        audioCaptureLog.info("🎙 Recording started on lifecycle queue ✅")
        completion(nil)
    }

    /// Stop a real recording or cancel an in-flight start. Resource teardown
    /// is serialized after setup and remains idempotent if setup observes the
    /// cancellation first.
    @MainActor
    @discardableResult
    func stopCapture() -> Data? {
        enum StopRequest {
            case teardown(CapturePhase, AudioCaptureStartToken)
            case waitForAutomaticFinalization
            case alreadyFinalized(Data?)
            case none
        }

        let request = lifecycleLock.withLock { () -> StopRequest in
            guard let activeCapture else {
                guard automaticallyFinalizedResultAvailable else { return .none }
                automaticallyFinalizedResultAvailable = false
                let wavData = automaticallyFinalizedWAV
                automaticallyFinalizedWAV = nil
                return .alreadyFinalized(wavData)
            }
            if activeCapture.phase == .finalizingAtLimit {
                return .waitForAutomaticFinalization
            }
            self.activeCapture = nil
            return .teardown(activeCapture.phase, activeCapture.token)
        }

        if case .waitForAutomaticFinalization = request {
            // The automatic finalizer owns teardown on this serial queue. Wait
            // for it, then consume the handoff result it published.
            captureQueue.sync {}
            return lifecycleLock.withLock {
                guard automaticallyFinalizedResultAvailable else { return nil }
                automaticallyFinalizedResultAvailable = false
                let wavData = automaticallyFinalizedWAV
                automaticallyFinalizedWAV = nil
                return wavData
            }
        }
        if case .alreadyFinalized(let wavData) = request { return wavData }
        guard case .teardown(let stoppedPhase, let token) = request else { return nil }

        let teardown = captureQueue.sync { [self] in
            teardownCaptureResources(
                buildWAV: stoppedPhase == .recording
            )
        }
        if teardown.shouldResumeKeyboardReady {
            BackgroundRecordingService.shared.resumeAfterForegroundCapture()
        }
        ForegroundAudioCaptureLeaseRegistry.shared.release(token)
        return teardown.wavData
    }

    func isCurrentStart(_ token: AudioCaptureStartToken) -> Bool {
        lifecycleLock.withLock {
            guard let activeCapture,
                  activeCapture.token == token,
                  case .starting = activeCapture.phase else { return false }
            return true
        }
    }

    func commitStart(_ token: AudioCaptureStartToken) -> Bool {
        lifecycleLock.withLock {
            guard var activeCapture,
                  activeCapture.token == token,
                  case .starting = activeCapture.phase else { return false }
            activeCapture.phase = .recording
            self.activeCapture = activeCapture
            return true
        }
    }

    func clearStartIfCurrent(_ token: AudioCaptureStartToken) -> Bool {
        lifecycleLock.withLock {
            guard let activeCapture, activeCapture.token == token else { return false }
            self.activeCapture = nil
            return true
        }
    }

    func scheduleMaximumDurationWatchdog(for token: AudioCaptureStartToken) {
        captureQueue.asyncAfter(
            deadline: .now() + AudioCapturePolicy.maximumDuration
        ) { [weak self] in
            self?.finishAtMaximumDurationIfCurrent(token: token)
        }
    }

    /// Called by either the wall-clock watchdog or the PCM sample bound. The
    /// lifecycle token makes delayed work from a stopped/replaced recording a
    /// no-op, and only one contender can take ownership of finalization.
    func finishAtMaximumDurationIfCurrent(token: AudioCaptureStartToken) {
        let capture = lifecycleLock.withLock { () -> ActiveCapture? in
            guard var activeCapture,
                  activeCapture.token == token,
                  case .recording = activeCapture.phase else { return nil }
            activeCapture.phase = .finalizingAtLimit
            self.activeCapture = activeCapture
            return activeCapture
        }
        guard let capture else { return }

        let teardown = teardownCaptureResources(buildWAV: true)
        lifecycleLock.withLock {
            guard activeCapture?.token == token,
                  activeCapture?.phase == .finalizingAtLimit else { return }
            activeCapture = nil
            automaticallyFinalizedWAV = teardown.wavData
            automaticallyFinalizedResultAvailable = true
        }
        ForegroundAudioCaptureLeaseRegistry.shared.release(token)
        if teardown.shouldResumeKeyboardReady {
            DispatchQueue.main.async {
                BackgroundRecordingService.shared.resumeAfterForegroundCapture()
            }
        }
        audioCaptureLog.info("🎙 Recording reached the five-minute limit and was finalized")
        capture.onMaximumDurationReached(teardown.wavData)
    }

    func requestMaximumDurationFinish(token: AudioCaptureStartToken) {
        captureQueue.async { [weak self] in
            self?.finishAtMaximumDurationIfCurrent(token: token)
        }
    }

    func finishStart(
        token: AudioCaptureStartToken,
        error: AudioCaptureError,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let wasCurrent = clearStartIfCurrent(token)
        let teardown = teardownCaptureResources(buildWAV: false)
        ForegroundAudioCaptureLeaseRegistry.shared.release(token)
        if teardown.shouldResumeKeyboardReady {
            DispatchQueue.main.async {
                BackgroundRecordingService.shared.resumeAfterForegroundCapture()
            }
        }
        completion(wasCurrent ? error : AudioCaptureError.startCancelled)
    }

    func teardownCaptureResources(
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

    @objc func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .began else { return }

        Task { @MainActor in
            let interruptionHandler: (@Sendable () -> Void)? = self.lifecycleLock.withLock {
                guard let activeCapture = self.activeCapture,
                      activeCapture.phase != .finalizingAtLimit else { return nil }
                return activeCapture.onInterruption
            }
            guard let interruptionHandler else { return }
            _ = self.stopCapture()
            interruptionHandler()
        }
    }
}
