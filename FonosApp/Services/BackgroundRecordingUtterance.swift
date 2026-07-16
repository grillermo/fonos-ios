import UIKit
@preconcurrency import AVFoundation
import SwiftData
import os.log

extension BackgroundRecordingService {
    func onStart() {
        DispatchQueue.main.async { [self] in
            replaceActiveKeyboardRequestIfNeeded()
            let requestedSessionID = readFile(KeyboardIPC.FileName.sessionID)
            preparedKeyboardWorkflow = nil
            expireReadySessionIfNeeded()
            sessionState.begin(sessionID: requestedSessionID)
            guard readySession?.isActive() == true,
                  foregroundCaptureDepth == 0,
                  engine.isRunning else {
                backgroundRecordingLog.error("🎙 Keyboard start rejected: Keyboard Ready is inactive")
                writeError("Open Fonos and enable Keyboard Ready, then try again.",
                           sessionID: sessionState.captureForResult())
                return
            }

            var config = readAppConfig()
            WorkflowMigration.migrate(&config)
            let workflowID = resolveWorkflowID(config: config)
            let catalog = config.workflowCatalog
            guard let definition = catalog.workflow(id: workflowID) else {
                writeError(
                    "Voice recipe is unavailable",
                    sessionID: sessionState.captureForResult()
                )
                return
            }
            let outputDescriptors: [KeyboardIPC.OutputDescriptor] = definition.outputs.compactMap { outputID in
                guard let widget = catalog.widget(id: outputID) else { return nil }
                return KeyboardIPC.OutputDescriptor(
                    typeTag: widget.typeTag,
                    pressEnter: widget.props["press_enter"]?.boolValue == true
                )
            }
            let delivery = KeyboardIPC.resolvedDelivery(outputs: outputDescriptors)
            let plan: ResolvedVoiceWorkflow
            do {
                plan = try compileKeyboardWorkflow(
                    definition: definition,
                    catalog: catalog,
                    config: config
                )
            } catch {
                backgroundRecordingLog.error("🎙 BG: recipe preflight failed: \(error.localizedDescription)")
                writeError(
                    "Recipe: \(error.localizedDescription)",
                    sessionID: sessionState.captureForResult()
                )
                return
            }

            recordingStartDate = Date()
            preparedKeyboardWorkflow = PreparedKeyboardWorkflow(
                sessionID: sessionState.captureForResult(),
                sourceStartedAt: recordingStartDate,
                definition: definition,
                plan: plan,
                delivery: delivery,
                destinationSummary: KeyboardWorkflowHistory.destinationSummary(
                    outputs: outputDescriptors
                )
            )
            let captureID = UUID()
            activeKeyboardCaptureID = captureID
            startCapturingUtterance(captureID: captureID)
            isKeyboardRecording = true
            scheduleUtteranceDeadline(
                captureID: captureID,
                sessionID: sessionState.captureForResult(),
                readyExpiresAt: readySession?.expiresAt ?? recordingStartDate
            )
            if let sessionID = sessionState.activeSessionID {
                writeFile(KeyboardIPC.FileName.startAckSessionID, sessionID)
            }
            writeStatus("recording")
            backgroundRecordingLog.info("🎙 Keyboard utterance started; session=\((self.sessionState.activeSessionID ?? "-").prefix(8))")
        }
    }

    /// A new keyboard session supersedes any stale processing result. Engine
    /// cancellation checks prevent remaining outputs from running; session
    /// guards prevent late file publication.
    func replaceActiveKeyboardRequestIfNeeded() {
        cancelProcessingTask()
        guard isKeyboardRecording else { return }
        let previousSessionID = sessionState.captureForResult()
        isKeyboardRecording = false
        activeKeyboardCaptureID = nil
        cancelUtteranceDeadline()
        stopCapturingUtterance()
        _ = writeError(
            "Recording was replaced by a newer keyboard request.",
            sessionID: previousSessionID
        )
    }

    func onCancel() {
        DispatchQueue.main.async { [self] in
            let requestedSessionID = readFile(KeyboardIPC.FileName.cancelSessionID)
            deleteFile(KeyboardIPC.FileName.cancelSessionID)
            guard sessionState.cancelIfActive(sessionID: requestedSessionID) else {
                if let requestedSessionID, !requestedSessionID.isEmpty {
                    backgroundRecordingLog.info("🎙 BG: ignored stale cancel for session \(requestedSessionID.prefix(8))")
                }
                return
            }

            isKeyboardRecording = false
            activeKeyboardCaptureID = nil
            cancelUtteranceDeadline()
            stopCapturingUtterance()
            preparedKeyboardWorkflow = nil
            cancelProcessingTask()
            writeStatus("cancelled")
            finishExpiredReadySessionIfPossible()
            backgroundRecordingLog.info("🎙 BG: cancelled keyboard session \((requestedSessionID ?? "-").prefix(8))")
        }
    }

    func onStop() {
        DispatchQueue.main.async { [self] in
            guard let captureID = activeKeyboardCaptureID else {
                backgroundRecordingLog.warning("Not keyboard-recording, ignoring stop")
                preparedKeyboardWorkflow = nil
                return
            }
            finishKeyboardUtterance(
                reason: .user,
                expectedCaptureID: captureID,
                expectedSessionID: sessionState.captureForResult()
            )
        }
    }

    @MainActor
    func finishKeyboardUtterance(
        reason: KeyboardUtteranceStopReason,
        expectedCaptureID: UUID,
        expectedSessionID: String?
    ) {
        guard isKeyboardRecording,
              activeKeyboardCaptureID == expectedCaptureID,
              sessionState.captureForResult() == expectedSessionID else {
            backgroundRecordingLog.info("🎙 Ignored stale keyboard utterance finalizer")
            return
        }

        cancelUtteranceDeadline()
        let capture = finishCapturingUtterance()
        isKeyboardRecording = false
        activeKeyboardCaptureID = nil
        let sessionID = expectedSessionID

        if reason == .readySessionExpired {
            publishReadiness(.finishing)
            // Seal PCM before tearing down the graph, then release the audio
            // session immediately. Transcription continues from the WAV only.
            if engine.isRunning {
                stopReadyEngine(removeTap: true, deactivateSession: true)
            }
        }
        guard let prepared = preparedKeyboardWorkflow,
              prepared.sessionID == sessionID else {
            preparedKeyboardWorkflow = nil
            writeError("Voice recipe snapshot expired. Try again.", sessionID: sessionID)
            finishExpiredReadySessionIfPossible()
            return
        }
        preparedKeyboardWorkflow = nil

        let wallDuration = max(0, Date().timeIntervalSince(recordingStartDate))
        backgroundRecordingLog.info(
            "🎙 BG: utterance finalized (\(String(describing: reason))); wall=\(String(format: "%.2f", wallDuration))s"
        )

        if capture.conversionFailed {
            writeError(
                String(localized: "Audio input changed while recording. Wait for Keyboard Ready, then try again."),
                sessionID: sessionID
            )
            finishExpiredReadySessionIfPossible()
            return
        }

        // `overflowed` means the buffer contains the complete bounded prefix.
        // Process it instead of throwing away the user's five-minute utterance.
        if capture.overflowed {
            backgroundRecordingLog.info("🎙 Keyboard PCM reached its five-minute sample bound")
        }
        let wavData = WAVSegment.build(
            from: capture.pcm[capture.pcm.startIndex..<capture.pcm.endIndex],
            sampleRate: AudioCapturePolicy.sampleRate
        )
        let capturedDuration = WAVSegment.duration(
            of: wavData,
            sampleRate: AudioCapturePolicy.sampleRate
        )
        guard capturedDuration >= 0.4, wavData.count > 100 else {
            writeError("No audio captured. Try again.", sessionID: sessionID)
            finishExpiredReadySessionIfPossible()
            return
        }

        var bgTaskID: UIBackgroundTaskIdentifier = .invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                backgroundRecordingLog.warning("🎙 BG: Background task expiring")
                self.expireProcessing(
                    sessionID: sessionID,
                    backgroundTaskID: bgTaskID
                )
            }
        }
        processingBackgroundTaskID = bgTaskID
        processingSessionID = sessionID

        writeStatus("processing")
        expireReadySessionIfNeeded()
        finishStop(
            wavData: wavData,
            sessionID: sessionID,
            wallDuration: wallDuration,
            bgTaskID: bgTaskID,
            prepared: prepared
        )
    }

    func finishStop(
        wavData: Data,
        sessionID: String?,
        wallDuration: TimeInterval,
        bgTaskID: UIBackgroundTaskIdentifier,
        prepared: PreparedKeyboardWorkflow
    ) {
        guard sessionState.activeSessionID == sessionID,
              processingSessionID == sessionID,
              processingBackgroundTaskID == bgTaskID else {
            backgroundRecordingLog.info("🎙 BG: abandoned cancelled/stale stop for session \((sessionID ?? "-").prefix(8))")
            endBackgroundTask(bgTaskID)
            return
        }
        let capturedDuration = WAVSegment.duration(of: wavData, sampleRate: 16_000)
        backgroundRecordingLog.info(
            """
            🎙 In-memory utterance: \(wavData.count) bytes, \
            captured=\(String(format: "%.2f", capturedDuration))s, \
            wall=\(String(format: "%.2f", wallDuration))s, session=\((sessionID ?? "-").prefix(8))
            """
        )

        transcribeAndProcess(
            wavData: wavData,
            sessionID: sessionID,
            bgTaskID: bgTaskID,
            prepared: prepared
        )
    }

    func scheduleUtteranceDeadline(
        captureID: UUID,
        sessionID: String?,
        readyExpiresAt: Date
    ) {
        cancelUtteranceDeadline()
        let deadline = KeyboardUtteranceDeadline.resolve(
            startedAt: recordingStartDate,
            readyExpiresAt: readyExpiresAt
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // This work item is installed only on DispatchQueue.main below.
            MainActor.assumeIsolated {
                self.finishKeyboardUtterance(
                    reason: deadline.reason,
                    expectedCaptureID: captureID,
                    expectedSessionID: sessionID
                )
            }
        }
        utteranceDeadlineWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline.date.timeIntervalSinceNow),
            execute: workItem
        )
    }

    func cancelUtteranceDeadline() {
        utteranceDeadlineWorkItem?.cancel()
        utteranceDeadlineWorkItem = nil
    }

    func updateHeartbeat() {
        guard foregroundCaptureDepth == 0 else {
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
            return
        }
        expireReadySessionIfNeeded()
        let now = Date()

        let acceptedOperationIsActive = isKeyboardRecording || processingSessionID != nil
        if acceptedOperationIsActive
            || (readySession?.isActive(at: now) == true && engine.isRunning) {
            writeFile(KeyboardIPC.FileName.appInstanceID, appInstanceID)
            writeFile(KeyboardIPC.FileName.heartbeat, "\(now.timeIntervalSince1970)")
        } else {
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
        }
    }

    func startCapturingUtterance(captureID: UUID) {
        captureLock.lock()
        acceptsCaptureBuffers = false
        capturedSamples.removeAll(keepingCapacity: true)
        capturedSamples.reserveCapacity(Self.maxUtteranceSamples)
        captureOverflowed = false
        captureConversionFailed = false
        captureLimitNotificationScheduled = false
        tapCaptureID = captureID
        readyAudioConverter?.reset()
        readyConverterInput.clear()
        acceptsCaptureBuffers = true
        captureLock.unlock()
    }

    func stopCapturingUtterance() {
        captureLock.lock()
        acceptsCaptureBuffers = false
        capturedSamples.removeAll(keepingCapacity: true)
        captureOverflowed = false
        captureConversionFailed = false
        captureLimitNotificationScheduled = false
        tapCaptureID = nil
        readyConverterInput.clear()
        captureLock.unlock()
    }

    func finishCapturingUtterance() -> KeyboardCaptureResult {
        captureLock.lock()
        acceptsCaptureBuffers = false
        let pcm = capturedSamples.withUnsafeBytes { Data($0) }
        let overflowed = captureOverflowed
        let conversionFailed = captureConversionFailed
        capturedSamples.removeAll(keepingCapacity: true)
        captureOverflowed = false
        captureConversionFailed = false
        captureLimitNotificationScheduled = false
        tapCaptureID = nil
        readyConverterInput.clear()
        captureLock.unlock()

        return KeyboardCaptureResult(
            pcm: pcm,
            overflowed: overflowed,
            conversionFailed: conversionFailed
        )
    }

    /// The tap runs for the bounded Ready window so iOS keeps the containing
    /// app's audio input alive in the background. Before a keyboard start, the
    /// fast guard returns and the buffer is neither converted nor retained.
    func processReadyTapBuffer(_ buffer: AVAudioPCMBuffer) {
        captureLock.lock()
        defer { captureLock.unlock() }
        guard acceptsCaptureBuffers else { return }
        guard readyConverterInputFormat?.isEqual(buffer.format) == true,
              let converter = readyAudioConverter,
              let converted = readyConvertedBuffer else {
            captureConversionFailed = true
            acceptsCaptureBuffers = false
            return
        }

        converted.frameLength = 0
        readyConverterInput.reset(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(
            to: converted,
            error: &conversionError,
            withInputFrom: readyConverterInputBlock
        )
        readyConverterInput.clear()
        guard status != .error,
              conversionError == nil,
              let samples = converted.int16ChannelData?[0] else {
            captureConversionFailed = true
            acceptsCaptureBuffers = false
            return
        }

        let available = Self.maxUtteranceSamples - capturedSamples.count
        let frameCount = Int(converted.frameLength)
        guard available > 0 else {
            captureOverflowed = true
            acceptsCaptureBuffers = false
            notifyMaximumKeyboardCaptureIfNeeded()
            return
        }
        let accepted = min(available, frameCount)
        capturedSamples.append(contentsOf: UnsafeBufferPointer(
            start: samples,
            count: accepted
        ))
        if accepted < frameCount || capturedSamples.count >= Self.maxUtteranceSamples {
            captureOverflowed = true
            acceptsCaptureBuffers = false
            notifyMaximumKeyboardCaptureIfNeeded()
        }
    }

    /// Must be called with `captureLock` held. The capture UUID, rather than the
    /// IPC session alone, prevents a delayed tap callback from finalizing a
    /// replacement utterance that reused the same keyboard session ID.
    func notifyMaximumKeyboardCaptureIfNeeded() {
        guard !captureLimitNotificationScheduled,
              let captureID = tapCaptureID else { return }
        captureLimitNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishKeyboardUtterance(
                reason: .maximumDuration,
                expectedCaptureID: captureID,
                expectedSessionID: self.sessionState.captureForResult()
            )
        }
    }

    func expireReadySessionIfNeeded(at now: Date = Date()) {
        guard let readySession, !readySession.isActive(at: now) else { return }
        guard !KeyboardReadyAudioSessionPolicy.shouldDeferExpiry(
            foregroundCaptureDepth: foregroundCaptureDepth
        ) else {
            // Foreground capture owns the shared AVAudioSession. Resume will
            // finish expiry after foreground teardown releases that ownership.
            publishReadiness(.paused)
            writeFile(KeyboardIPC.FileName.heartbeat, "0")
            return
        }
        if isKeyboardRecording, let captureID = activeKeyboardCaptureID {
            publishReadiness(.finishing)
            // Every caller is on the main queue (heartbeat, lifecycle observer,
            // or a runOnMainSync bridge); make that executor contract explicit.
            MainActor.assumeIsolated {
                finishKeyboardUtterance(
                    reason: .readySessionExpired,
                    expectedCaptureID: captureID,
                    expectedSessionID: sessionState.captureForResult()
                )
            }
            return
        }
        if processingSessionID != nil {
            publishReadiness(.finishing)
            // Processing uses the already finalized WAV and never needs to
            // retain the live microphone graph after Ready expires.
            if engine.isRunning {
                stopReadyEngine(removeTap: true, deactivateSession: true)
            }
            return
        }
        disableKeyboardReadySession(reason: .expired, notifyActiveKeyboard: false)
    }

    func finishExpiredReadySessionIfPossible() {
        guard readySession?.isActive() == false,
              !isKeyboardRecording,
              processingSessionID == nil else { return }
        disableKeyboardReadySession(reason: .expired, notifyActiveKeyboard: false)
    }

    func disableKeyboardReadySession(
        reason: KeyboardIPC.ReadinessStatus,
        notifyActiveKeyboard: Bool
    ) {
        if notifyActiveKeyboard, let sessionID = sessionState.activeSessionID {
            _ = writeError("Keyboard Ready ended in Fonos.", sessionID: sessionID)
        }
        isKeyboardRecording = false
        activeKeyboardCaptureID = nil
        cancelUtteranceDeadline()
        preparedKeyboardWorkflow = nil
        stopCapturingUtterance()
        cancelProcessingTask()
        sessionState = KeyboardIPCProducerSessionState()
        stopReadyEngine(
            removeTap: true,
            deactivateSession: KeyboardReadyAudioSessionPolicy.shouldDeactivateSession(
                foregroundCaptureDepth: foregroundCaptureDepth
            )
        )
        readySession = nil
        deleteFile(KeyboardIPC.FileName.continuousAudio)
        deleteFile(KeyboardIPC.FileName.segmentAudio)
        writeFile(KeyboardIPC.FileName.heartbeat, "0")
        publishReadiness(reason)
    }

    func publishReadiness(_ status: KeyboardIPC.ReadinessStatus) {
        readinessStatus = status
        writeFile(KeyboardIPC.FileName.readinessStatus, status.rawValue)
        if let readySession {
            writeFile(KeyboardIPC.FileName.readySessionID, readySession.id)
            writeFile(
                KeyboardIPC.FileName.readyExpiresAt,
                "\(readySession.expiresAt.timeIntervalSince1970)"
            )
        } else {
            deleteFile(KeyboardIPC.FileName.readySessionID)
            deleteFile(KeyboardIPC.FileName.readyExpiresAt)
        }
        NotificationCenter.default.post(
            name: .keyboardReadySessionDidChange,
            object: self
        )
    }

    // MARK: - Transcribe & Process

}
