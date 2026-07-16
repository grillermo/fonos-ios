import UIKit
@preconcurrency import AVFoundation
import SwiftData
import os.log

extension BackgroundRecordingService {
    @MainActor
    var keyboardReadySession: KeyboardReadySession? {
        readySession
    }

    @MainActor
    var isKeyboardReady: Bool {
        readySession?.isActive() == true
            && foregroundCaptureDepth == 0
            && engine.isRunning
    }

    @MainActor
    var keyboardReadinessStatus: KeyboardIPC.ReadinessStatus {
        readinessStatus
    }

    /// Starts or renews the bounded Keyboard Ready window. This must be called
    /// from an explicit user action while the containing app is foregrounded.
    @MainActor
    func enableKeyboardReadySession(
        duration: TimeInterval = KeyboardIPC.defaultReadySessionDuration
    ) async throws -> KeyboardReadySession {
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        @unknown default:
            granted = false
        }
        guard granted else {
            throw KeyboardReadySessionError.microphonePermissionDenied
        }

        do {
            try startReadyEngine()
        } catch let error as KeyboardReadySessionError {
            throw error
        } catch {
            throw KeyboardReadySessionError.engineStartFailed(error)
        }

        let now = Date()
        let clampedDuration = KeyboardIPC.clampedReadySessionDuration(duration)
        let session = KeyboardReadySession(
            id: readySession?.id ?? UUID().uuidString,
            startedAt: readySession?.startedAt ?? now,
            expiresAt: now.addingTimeInterval(clampedDuration)
        )
        readySession = session
        if let captureID = activeKeyboardCaptureID,
           isKeyboardRecording {
            scheduleUtteranceDeadline(
                captureID: captureID,
                sessionID: sessionState.captureForResult(),
                readyExpiresAt: session.expiresAt
            )
        }
        publishReadiness(.ready)
        updateHeartbeat()
        backgroundRecordingLog.info("🎙 Keyboard Ready enabled until \(session.expiresAt, privacy: .public)")
        return session
    }

    @MainActor
    func disableKeyboardReadySession() {
        disableKeyboardReadySession(reason: .inactive, notifyActiveKeyboard: true)
    }

    func startReadyEngine() throws {
        if engine.isRunning,
           inputTapInstalled,
           readyAudioConverter != nil,
           readyConvertedBuffer != nil {
            return
        }

        isManagingReadyEngine = true
        var didStart = false
        defer {
            if !didStart {
                stopReadyEngine(removeTap: true, deactivateSession: true)
            }
            isManagingReadyEngine = false
        }

        if engine.isRunning {
            stopReadyEngine(removeTap: true, deactivateSession: true)
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothHFP]
            )
            try session.setPreferredSampleRate(16_000)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw KeyboardReadySessionError.engineStartFailed(error)
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw KeyboardReadySessionError.noAudioInput
        }

        let formatChanged = readyConverterInputFormat.map {
            !$0.isEqual(inputFormat)
        } ?? true
        if inputTapInstalled && formatChanged {
            inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
            clearReadyCapturePipeline(releaseStorage: false)
        }

        if !inputTapInstalled {
            try prepareReadyCapturePipeline(inputFormat: inputFormat)
            inputNode.installTap(
                onBus: 0,
                bufferSize: Self.tapBufferSize,
                format: nil
            ) { [weak self] buffer, _ in
                self?.processReadyTapBuffer(buffer)
            }
            inputTapInstalled = true
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw KeyboardReadySessionError.engineStartFailed(error)
        }
        didStart = true
        suppressGraphChangesUntil = Date().addingTimeInterval(0.75)
        backgroundRecordingLog.info("🎙 Keyboard Ready input graph running; idle buffers are discarded")
    }

    func stopReadyEngine(removeTap: Bool, deactivateSession: Bool) {
        let wasManaging = isManagingReadyEngine
        isManagingReadyEngine = true
        defer { isManagingReadyEngine = wasManaging }

        stopCapturingUtterance()
        engine.stop()
        if removeTap, inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        if removeTap {
            clearReadyCapturePipeline(releaseStorage: true)
        }
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    func prepareReadyCapturePipeline(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
            throw KeyboardReadySessionError.engineStartFailed(
                KeyboardReadyCaptureSetupError.converterUnavailable
            )
        }
        let ratio = captureFormat.sampleRate / inputFormat.sampleRate
        let convertedCapacity = max(
            Self.tapBufferSize,
            AVAudioFrameCount(ceil(Double(Self.tapBufferSize) * ratio)) + 1_024
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: convertedCapacity
        ) else {
            throw KeyboardReadySessionError.engineStartFailed(
                KeyboardReadyCaptureSetupError.outputBufferUnavailable
            )
        }

        readyAudioConverter = converter
        readyConvertedBuffer = convertedBuffer
        readyConverterInputFormat = inputFormat
        _ = readyConverterInputBlock // Materialize the closure off the tap thread.
        captureLock.lock()
        capturedSamples.reserveCapacity(Self.maxUtteranceSamples)
        captureLock.unlock()
    }

    func clearReadyCapturePipeline(releaseStorage: Bool) {
        captureLock.lock()
        readyConverterInput.clear()
        readyAudioConverter = nil
        readyConvertedBuffer = nil
        readyConverterInputFormat = nil
        acceptsCaptureBuffers = false
        captureOverflowed = false
        captureConversionFailed = false
        captureLimitNotificationScheduled = false
        tapCaptureID = nil
        if releaseStorage {
            capturedSamples = []
        } else {
            capturedSamples.removeAll(keepingCapacity: true)
        }
        captureLock.unlock()
    }

    func handleReadyAudioLoss(
        _ loss: KeyboardReadyAudioLoss,
        recoverAutomatically: Bool,
        recreateEngine: Bool = false
    ) {
        guard readySession != nil, foregroundCaptureDepth == 0 else { return }
        expireReadySessionIfNeeded()
        guard readySession?.isActive() == true else { return }

        if isKeyboardRecording {
            let sessionID = sessionState.captureForResult()
            isKeyboardRecording = false
            activeKeyboardCaptureID = nil
            cancelUtteranceDeadline()
            preparedKeyboardWorkflow = nil
            stopCapturingUtterance()
            _ = writeError(loss.userMessage, sessionID: sessionID)
            finishExpiredReadySessionIfPossible()
        } else {
            stopCapturingUtterance()
        }
        guard readySession != nil else { return }
        publishReadiness(.paused)
        writeFile(KeyboardIPC.FileName.heartbeat, "0")

        if recoverAutomatically {
            scheduleReadyEngineRecovery(
                after: 0.2,
                recreateEngine: recreateEngine
            )
        } else {
            scheduleReadyEngineTeardown(recreateEngine: recreateEngine)
        }
    }

    func scheduleReadyEngineTeardown(recreateEngine: Bool) {
        readyEngineRecoveryGeneration += 1
        let generation = readyEngineRecoveryGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.readyEngineRecoveryGeneration else { return }
            self.stopReadyEngine(removeTap: true, deactivateSession: true)
            if recreateEngine {
                self.engine = AVAudioEngine()
            }
        }
    }

    func scheduleReadyEngineRecovery(
        after delay: TimeInterval,
        recreateEngine: Bool = false
    ) {
        readyEngineRecoveryGeneration += 1
        let generation = readyEngineRecoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.readyEngineRecoveryGeneration else { return }
            self.expireReadySessionIfNeeded()
            guard self.readySession?.isActive() == true,
                  self.foregroundCaptureDepth == 0 else { return }

            self.stopReadyEngine(removeTap: true, deactivateSession: true)
            if recreateEngine {
                self.engine = AVAudioEngine()
            }
            do {
                try self.startReadyEngine()
                self.publishReadiness(.ready)
                self.updateHeartbeat()
                backgroundRecordingLog.info("🎙 Keyboard Ready audio graph recovered")
            } catch {
                self.publishReadiness(.paused)
                self.writeFile(KeyboardIPC.FileName.heartbeat, "0")
                backgroundRecordingLog.error("🎙 Keyboard Ready recovery failed: \(error.localizedDescription)")
            }
        }
    }

    /// Pause Keyboard Ready while the foreground Dictate surface owns audio.
    func pauseForForegroundCapture() {
        runOnMainSync { [self] in
            foregroundCaptureDepth += 1
            guard foregroundCaptureDepth == 1 else { return }

            // If a keyboard utterance is still open, seal and process the audio
            // collected so far before handing AVAudioSession to the foreground.
            // An already-running STT/LLM task does not own the microphone and
            // must be allowed to publish its result normally.
            if let captureID = activeKeyboardCaptureID, isKeyboardRecording {
                MainActor.assumeIsolated {
                    finishKeyboardUtterance(
                        reason: .user,
                        expectedCaptureID: captureID,
                        expectedSessionID: sessionState.captureForResult()
                    )
                }
            }
            stopReadyEngine(removeTap: false, deactivateSession: false)
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
            if readySession != nil { publishReadiness(.paused) }
            backgroundRecordingLog.info("🎙 Keyboard Ready paused for foreground capture")
        }
    }

    /// Resume keyboard readiness after foreground app dictation releases the
    /// audio session. Must be called while the app is foreground-capable.
    func resumeAfterForegroundCapture() {
        runOnMainSync { [self] in
            guard foregroundCaptureDepth > 0 else { return }
            foregroundCaptureDepth -= 1
            guard foregroundCaptureDepth == 0 else { return }

            expireReadySessionIfNeeded()
            guard readySession?.isActive() == true else { return }
            do {
                try startReadyEngine()
                // Preserve an in-flight or newly completed keyboard result.
                // This is the same app instance; only its input graph restarted.
                writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
                publishReadiness(.ready)
                updateHeartbeat()
                backgroundRecordingLog.info("🎙 Keyboard Ready resumed after foreground capture")
            } catch {
                publishReadiness(.paused)
                backgroundRecordingLog.error("🎙 Keyboard Ready resume failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Keyboard utterance

}
