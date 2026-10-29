import Foundation
import SwiftUI
import SwiftData
import os.log

extension DictationViewModel {
    @MainActor
    func startRecording() {
        dictationLog.info("▶️ startRecording() called, isRecording=\(self.isRecording)")
        guard !isRunBusy else {
            dictationLog.warning("⚠️ A capture or processing run is active, ignoring start")
            return
        }

        resetFlowUI()
        let captureStartID = UUID()
        activeCaptureStartID = captureStartID
        // Permission wait is part of the start lifecycle. Publishing `.starting`
        // now prevents a second manual/deep-link request from replacing this
        // run's frozen workflow or one-shot destination.
        recordingState = .starting

        let permission = audioCapture.micPermissionStatus()
        dictationLog.info("🎤 Mic permission status: \(String(describing: permission.rawValue))")

        switch permission {
        case .granted:
            dictationLog.info("✅ Permission granted, calling doStartCapture()")
            doStartCapture(captureStartID: captureStartID)
        case .undetermined:
            dictationLog.info("❓ Permission undetermined, requesting...")
            Task { @MainActor in
                let granted = await audioCapture.requestMicPermission()
                dictationLog.info("🎤 Permission request result: \(granted)")
                guard activeCaptureStartID == captureStartID,
                      case .starting = recordingState else {
                    dictationLog.info("🎤 Ignored stale permission result")
                    return
                }
                if granted {
                    doStartCapture(captureStartID: captureStartID)
                } else {
                    activeCaptureStartID = nil
                    pendingOneShotDestination = nil
                    recordingState = .error(message: "Microphone permission is required. Please enable it in Settings.")
                }
            }
        case .denied:
            dictationLog.error("❌ Permission denied")
            activeCaptureStartID = nil
            pendingOneShotDestination = nil
            recordingState = .error(message: "Microphone permission denied. Go to Settings → Privacy → Microphone to enable.")
        @unknown default:
            dictationLog.error("❌ Permission unknown")
            activeCaptureStartID = nil
            pendingOneShotDestination = nil
            recordingState = .error(message: "Microphone permission unavailable.")
        }
    }

    @MainActor
    func doStartCapture(captureStartID: UUID) {
        dictationLog.info("🔴 doStartCapture() — starting engine on background thread")

        guard activeCaptureStartID == captureStartID,
              case .starting = recordingState else {
            dictationLog.warning("⚠️ Capture request became stale while awaiting permission")
            return
        }

        let prepared: PreparedMainWorkflow
        do {
            prepared = try prepareNextMainWorkflow()
        } catch {
            dictationLog.error("❌ Recipe preflight failed: \(error.localizedDescription)")
            activeCaptureStartID = nil
            recordingState = .error(message: error.localizedDescription)
            return
        }
        preparedMainWorkflow = prepared
        workflowPresentation = WorkflowRunPresentation(
            runID: prepared.runID,
            definition: prepared.surface.definition,
            catalog: prepared.surface.catalog
        )
        sttLatency = 0
        llmLatency = 0

        // Expose setup truthfully. The red recording state begins only after
        // AVAudioEngine has actually started.
        // Start audio engine on background thread to avoid blocking main thread
        audioCapture.startCapture(
            onInterruption: { [weak self] in
                DispatchQueue.main.async {
                    self?.handleCaptureInterruption()
                }
            },
            onMaximumDurationReached: { [weak self] wavData in
                DispatchQueue.main.async {
                    self?.handleCaptureDurationLimit(
                        runID: prepared.runID,
                        wavData: wavData
                    )
                }
            },
            completion: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self,
                          self.activeCaptureStartID == captureStartID else { return }
                    self.activeCaptureStartID = nil
                    if let error {
                        dictationLog.error("❌ Engine start failed: \(error.localizedDescription)")
                        self.preparedMainWorkflow = nil
                        self.recordingState = .error(message: error.localizedDescription)
                        self.stopLevelPolling()
                    } else {
                        dictationLog.info("✅ Engine started successfully on background thread")
                        self.workflowPresentation.beginSourceCapture()
                        self.recordingState = .recording
                        self.startLevelPolling()
                    }
                }
            }
        )
    }

    @MainActor
    func stopRecording() {
        dictationLog.info("⏹ stopRecording() called")
        switch recordingState {
        case .starting:
            activeCaptureStartID = nil
            _ = audioCapture.stopCapture()
            preparedMainWorkflow = nil
            stopLevelPolling()
            recordingState = .idle
            resetFlowUI()

        case .recording:
            stopLevelPolling()
            let wavData = audioCapture.stopCapture()
            dictationLog.info("⏹ Got WAV data: \(wavData?.count ?? 0) bytes")
            finishRecording(wavData: wavData ?? Data())

        case .idle, .processing, .result, .error:
            return
        }
    }

    @MainActor
    func handleCaptureInterruption() {
        guard isCaptureActive else { return }
        activeCaptureStartID = nil
        preparedMainWorkflow = nil
        stopLevelPolling()
        resetFlowUI()
        recordingState = .error(
            message: "Recording was interrupted. Please try again."
        )
    }

    @MainActor
    func handleCaptureDurationLimit(runID: UUID, wavData: Data?) {
        guard case .recording = recordingState,
              preparedMainWorkflow?.runID == runID else {
            dictationLog.info("🎙 Ignored stale recording-limit callback")
            return
        }

        activeCaptureStartID = nil
        stopLevelPolling()
        guard let wavData, !wavData.isEmpty else {
            preparedMainWorkflow = nil
            resetFlowUI()
            recordingState = .error(
                message: "Recording reached the five-minute limit, but the audio could not be finalized. Please try again."
            )
            return
        }

        dictationLog.info("⏱ Recording reached five minutes; processing the complete bounded capture")
        finishRecording(wavData: wavData)
    }

    /// Executes the source → processors → outputs plan frozen at capture start.
    /// Tests and non-capture callers get the same preflight as a fallback.
    @MainActor
    func finishRecording(wavData: Data) {
        if case .processing = recordingState {
            dictationLog.warning("⚠️ Ignored duplicate finish while processing is active")
            return
        }
        finishRecordingWhenIdle(wavData: wavData)
    }

    @MainActor
    func finishRecordingWhenIdle(wavData: Data) {
        let prepared: PreparedMainWorkflow
        do {
            prepared = try preparedMainWorkflow ?? prepareNextMainWorkflow()
        } catch {
            dictationLog.error("❌ Recipe preflight failed: \(error.localizedDescription)")
            recordingState = .error(message: error.localizedDescription)
            return
        }
        preparedMainWorkflow = nil
        runMainWorkflow(prepared, wavData: wavData, retryingPendingID: nil)
    }

    /// Runs a prepared plan on captured or saved audio. A failure before any
    /// text reached History keeps the audio for retry; a retry that fails
    /// again only records the attempt.
    @MainActor
    func runMainWorkflow(
        _ prepared: PreparedMainWorkflow,
        wavData: Data,
        retryingPendingID: UUID?
    ) {
        let processingID = prepared.runID
        activeProcessingID = processingID
        activeRunPersistedText = false
        lastPendingRecordingID = nil
        // A retried item is busy for the whole run, so Discard and a quiet
        // retry cannot touch it mid-flight.
        if let retryingPendingID { retryingPendingIDs.insert(retryingPendingID) }
        if workflowPresentation.runID != processingID {
            workflowPresentation = WorkflowRunPresentation(
                runID: processingID,
                definition: prepared.surface.definition,
                catalog: prepared.surface.catalog
            )
        }
        sttLatency = 0
        llmLatency = 0
        recordingState = .processing

        processingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let retryingPendingID { retryingPendingIDs.remove(retryingPendingID) }
                if activeProcessingID == processingID {
                    activeProcessingID = nil
                    processingTask = nil
                }
            }

            do {
                dictationLog.info("🔄 Running voice recipe \(prepared.persistedDefinition.id, privacy: .public)...")
                let workflowResult = try await VoiceWorkflowEngine().run(
                    VoiceWorkflowRunInput(
                        runID: processingID,
                        audioData: wavData,
                        source: prepared.compiled.plan.validation.sourceKind,
                        sourceAcquisitionDuration: Date().timeIntervalSince(
                            prepared.sourceStartedAt
                        ),
                        dryRun: false
                    ),
                    using: prepared.compiled.plan,
                    onEvent: { [weak self] event in
                        await self?.receiveWorkflowEvent(event)
                    },
                    recorder: { [weak self] processed in
                        await self?.persistSession(
                            processed: processed,
                            definition: prepared.persistedDefinition,
                            destination: prepared.surface.destinationSummary
                        )
                    }
                )
                guard activeProcessingID == processingID, !Task.isCancelled else { return }
                updateLatencies(from: workflowResult)
                dictationLog.info("✅ Processing complete: \(workflowResult.finalText.prefix(50))...")
                workflowPresentation.complete(with: workflowResult)
                if let retryingPendingID {
                    pendingStore.discard(id: retryingPendingID)
                }
                lastPendingRecordingID = nil
                recordingState = .result(
                    transcript: workflowResult.rawText,
                    processed: workflowResult.finalText == workflowResult.rawText
                        ? nil
                        : workflowResult.finalText
                )

            } catch is CancellationError {
                dictationLog.info("⏹ Processing cancelled")
            } catch {
                guard activeProcessingID == processingID else { return }
                dictationLog.error("❌ Processing failed: \(error.localizedDescription)")
                handleMainRunFailure(
                    error,
                    wavData: wavData,
                    workflowID: prepared.persistedDefinition.id,
                    retryingPendingID: retryingPendingID
                )
                recordingState = .error(message: error.localizedDescription)
            }
        }
    }

    /// Decides what a failed run leaves behind. Text already in History means
    /// there is nothing to retry: a retried item is then discarded.
    @MainActor
    func handleMainRunFailure(
        _ error: Error,
        wavData: Data,
        workflowID: String,
        retryingPendingID: UUID?
    ) {
        if let retryingPendingID {
            if activeRunPersistedText {
                pendingStore.discard(id: retryingPendingID)
                lastPendingRecordingID = nil
            } else {
                pendingStore.recordAttempt(id: retryingPendingID, error: error.localizedDescription)
                lastPendingRecordingID = pendingStore.recording(id: retryingPendingID) != nil
                    ? retryingPendingID
                    : nil
            }
            return
        }
        guard !activeRunPersistedText,
              PendingRecordingStore.shouldKeep(error: error, audio: wavData) else { return }
        do {
            lastPendingRecordingID = try pendingStore.save(
                wav: wavData,
                surface: .dictate,
                workflowID: workflowID,
                error: error.localizedDescription
            ).id
        } catch let saveError {
            dictationLog.error("❌ Could not keep the recording for retry: \(saveError.localizedDescription)")
        }
    }

    @MainActor
    func resetFlowUI() {
        workflowPresentation = .idle
        frozenSTTProviderName = nil
        frozenLLMProviderName = nil
        sttLatency = 0
        llmLatency = 0
        lastPendingRecordingID = nil
    }

    @MainActor
    func receiveWorkflowEvent(_ event: VoiceWorkflowTraceEvent) {
        let runID: UUID
        switch event {
        case .runStarted(let id, _),
             .stepStarted(let id, _, _),
             .stepFinished(let id, _, _, _, _),
             .runSucceeded(let id, _, _),
             .runFailed(let id, _, _, _),
             .runCancelled(let id, _, _, _):
            runID = id
        }
        guard activeProcessingID == runID else { return }
        workflowPresentation.apply(event)
    }

    @MainActor
    func updateLatencies(from result: VoiceWorkflowResult) {
        let sttDuration = result.timings.steps
            .filter { $0.step.typeTag == "stt" }
            .reduce(0) { $0 + $1.duration }
        let llmSteps = result.timings.steps.filter { $0.step.typeTag == "llm" }
        let llmDuration = llmSteps.isEmpty
            ? nil
            : llmSteps.reduce(0) { $0 + $1.duration }
        sttLatency = sttDuration
        llmLatency = llmDuration ?? 0
    }

    /// Engine recorder hook: persists after processors but before outputs, so
    /// a failed delivery still leaves recoverable text in History.
    @MainActor
    func persistSession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition,
        destination: String
    ) {
        lastSession = insertSession(
            processed: processed,
            definition: definition,
            destination: destination
        )
        // Only a session that was inserted and saved counts as recoverable text.
        activeRunPersistedText = lastSession != nil
    }

    @MainActor
    func insertSession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition,
        destination: String
    ) -> DictationSession? {
        guard let context = modelContext else { return nil }
        let legacyModeID = WorkflowMigration.legacyModeID(
            forWorkflowID: definition.id
        )
        let session = DictationSession(
            date: Date(),
            workflowID: definition.id,
            workflowName: definition.name,
            mode: legacyModeID ?? definition.id,
            inputText: processed.rawText,
            outputText: processed.finalText,
            destination: destination,
            latencyMs: processed.timings.total * 1_000
        )
        context.insert(session)
        do {
            try context.save()
        } catch {
            // History is non-essential: match desktop DbRecorder by absorbing
            // local persistence failures instead of failing dictation.
            dictationLog.error("❌ Failed to persist workflow record: \(error.localizedDescription)")
            return nil
        }
        return session
    }

    /// Replaces the shown result with the user's edit and updates its History
    /// entry. The raw transcript is kept, so the edit shows as the final text.
    @MainActor
    func updateResultText(_ text: String) {
        guard case .result(let transcript, let processed) = recordingState,
              text != (processed ?? transcript) else { return }
        recordingState = .result(transcript: transcript, processed: text == transcript ? nil : text)
        guard let session = lastSession else { return }
        session.outputText = text
        do {
            try modelContext?.save()
        } catch {
            dictationLog.error("❌ Failed to save edited result: \(error.localizedDescription)")
        }
    }

    // MARK: - Pending recordings

    /// Retry from the Dictate error card: the saved recipe, compiled from
    /// current settings, with its outputs, shown like a fresh recording.
    @MainActor
    func retryPendingRecording(_ id: UUID) {
        guard !isRunBusy, !retryingPendingIDs.contains(id) else { return }
        resetFlowUI()
        do {
            let pending = try retryableRecording(id)
            let wavData = try pendingStore.audio(id: id)
            let prepared = try prepareMainWorkflow(workflowID: pending.workflowID)
            workflowPresentation = WorkflowRunPresentation(
                runID: prepared.runID,
                definition: prepared.surface.definition,
                catalog: prepared.surface.catalog
            )
            runMainWorkflow(prepared, wavData: wavData, retryingPendingID: id)
        } catch {
            dictationLog.error("❌ Retry could not start: \(error.localizedDescription)")
            pendingStore.recordAttempt(id: id, error: error.localizedDescription)
            // Point the card at the item only while it still exists.
            lastPendingRecordingID = pendingStore.recording(id: id) != nil ? id : nil
            recordingState = .error(message: error.localizedDescription)
        }
    }

    /// Retry from History: saves the text and copies it, without running the
    /// recipe's outputs or touching the Dictate screen. The audio is only
    /// discarded once the text is safely in History.
    @MainActor
    @discardableResult
    func retryPendingRecordingQuietly(_ id: UUID) async throws -> String {
        guard !isRunBusy else { throw PendingRecordingError.dictationBusy }
        guard !retryingPendingIDs.contains(id) else { throw PendingRecordingError.alreadyRetrying }
        retryingPendingIDs.insert(id)
        defer { retryingPendingIDs.remove(id) }

        let saved = QuietRetrySaveFlag()
        do {
            let pending = try retryableRecording(id)
            let wavData = try pendingStore.audio(id: id)
            let (definition, compiled) = try compileQuietRetry(workflowID: pending.workflowID)
            let result = try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(
                    audioData: wavData,
                    source: compiled.plan.validation.sourceKind
                ),
                using: compiled.plan,
                recorder: { [weak self] processed in
                    let inserted = await self?.persistRetrySession(
                        processed: processed,
                        definition: definition
                    ) ?? false
                    saved.set(inserted)
                }
            )
            if saved.value {
                pendingStore.discard(id: id)
            }
            try Task.checkCancellation()
            copyText(result.finalText)
            return result.finalText
        } catch {
            handleQuietRetryFailure(error, id: id, textSaved: saved.value)
            throw error
        }
    }

    /// A cancelled retry is not a failed attempt, and text already in History
    /// makes the audio redundant whatever stopped the run afterwards.
    @MainActor
    func handleQuietRetryFailure(_ error: Error, id: UUID, textSaved: Bool) {
        if textSaved {
            pendingStore.discard(id: id)
        } else if !(error is CancellationError) {
            pendingStore.recordAttempt(id: id, error: error.localizedDescription)
        }
    }

    /// Returns false, changing nothing, while the item is being retried.
    @MainActor
    @discardableResult
    func discardPendingRecording(_ id: UUID) -> Bool {
        guard !retryingPendingIDs.contains(id) else { return false }
        pendingStore.discard(id: id)
        guard lastPendingRecordingID == id else { return true }
        lastPendingRecordingID = nil
        if case .error = recordingState {
            recordingState = .idle
            resetFlowUI()
        }
        return true
    }

    @MainActor
    private func retryableRecording(_ id: UUID) throws -> PendingRecording {
        guard let pending = pendingStore.recording(id: id) else {
            throw PendingRecordingError.notFound
        }
        guard let workflowID = pending.workflowID,
              config.workflowCatalog.workflow(id: workflowID) != nil else {
            throw PendingRecordingError.recipeUnavailable
        }
        return pending
    }

    /// The recipe with its outputs swapped for return-to-caller, so a quiet
    /// retry yields text and nothing else.
    @MainActor
    private func compileQuietRetry(
        workflowID: String?
    ) throws -> (WorkflowDefinition, VoiceWorkflowPlanFactory.Compilation) {
        WorkflowMigration.migrate(&config)
        let catalog = config.workflowCatalog
        guard let workflowID, let definition = catalog.workflow(id: workflowID) else {
            throw PendingRecordingError.recipeUnavailable
        }
        let widgetID = "out.ios-retry"
        var quietCatalog = catalog
        quietCatalog.widgets.removeAll { $0.id == widgetID }
        quietCatalog.widgets.append(WorkflowWidget(
            id: widgetID,
            role: .output,
            typeTag: "return_to_caller",
            name: String(localized: "Retry"),
            icon: "arrow.clockwise"
        ))
        var quietDefinition = definition
        quietDefinition.outputs = [widgetID]
        let compiled = try compileMainWorkflow(
            definition: quietDefinition,
            catalog: quietCatalog,
            legacyScopeID: legacyScopeID(for: definition),
            outputsByWidgetID: [:]
        )
        return (definition, compiled)
    }

    /// Returns whether the session was really saved to History.
    @MainActor
    private func persistRetrySession(
        processed: VoiceWorkflowProcessedResult,
        definition: WorkflowDefinition
    ) -> Bool {
        insertSession(processed: processed, definition: definition, destination: "result") != nil
    }

    @MainActor
    func sendToDestination(_ destination: AnyTextDestination) {
        guard case .result(let transcript, let processed) = recordingState else { return }
        let text = processed ?? transcript
        Task {
            try? await destination.send(text: text)
        }
    }

}

/// Carries "the text reached History" out of the engine's `@Sendable` recorder.
private final class QuietRetrySaveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set(_ newValue: Bool) { lock.withLock { stored = newValue } }
}
