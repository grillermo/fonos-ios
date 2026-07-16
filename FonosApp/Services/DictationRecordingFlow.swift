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
        let processingID = prepared.runID
        activeProcessingID = processingID
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
                recordingState = .error(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    func resetFlowUI() {
        workflowPresentation = .idle
        frozenSTTProviderName = nil
        frozenLLMProviderName = nil
        sttLatency = 0
        llmLatency = 0
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
        guard let context = modelContext else { return }
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
        }
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
