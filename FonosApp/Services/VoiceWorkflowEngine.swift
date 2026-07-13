import Foundation

// MARK: - Engine

struct VoiceWorkflowEngine: Sendable {
    private let clock = ContinuousClock()

    // Keep construction module-visible after splitting compiler/factory code;
    // the synthesized memberwise initializer would inherit the private clock.
    init() {}

    /// Execute every compiled component in definition order.
    func run(
        _ input: VoiceWorkflowRunInput,
        using workflow: ResolvedVoiceWorkflow,
        onEvent: VoiceWorkflowEventHandler? = nil,
        recorder: VoiceWorkflowRunRecorder? = nil
    ) async throws -> VoiceWorkflowResult {
        guard input.source == workflow.source.kind else {
            throw VoiceWorkflowRuntimeError.sourceInputMismatch(
                expected: workflow.source.kind,
                actual: input.source
            )
        }
        try Task.checkCancellation()

        let workflowID = workflow.definition.id
        var state = VoiceWorkflowExecutionState()
        let started = VoiceWorkflowTraceEvent.runStarted(
            runID: input.runID,
            workflowID: workflowID
        )
        await emit(started, state: &state, onEvent: onEvent)

        do {
            try await acquireSource(
                input,
                workflow: workflow,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )

            var value = VoiceWorkflowPipelineValue(audio: input.audioData)
            try await process(
                workflow.processors,
                input: input,
                workflowID: workflowID,
                value: &value,
                state: &state,
                onEvent: onEvent
            )

            guard let finalText = value.text,
                  let rawText = value.rawText,
                  let providerTranscript = value.providerTranscript else {
                throw VoiceWorkflowRuntimeError.internalKindMismatch(
                    widgetID: workflow.definition.processors.last ?? workflow.source.widget.id
                )
            }

            try await recordProcessedResult(
                input: input,
                workflowID: workflowID,
                providerTranscript: providerTranscript,
                rawText: rawText,
                finalText: finalText,
                recorder: recorder,
                state: state
            )
            try await deliver(
                workflow.outputs,
                finalText: finalText,
                input: input,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )

            return try await completeRun(
                input: input,
                workflowID: workflowID,
                providerTranscript: providerTranscript,
                rawText: rawText,
                finalText: finalText,
                state: &state,
                onEvent: onEvent
            )
        } catch {
            return try await terminateRun(
                after: error,
                input: input,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )
        }
    }

    private func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct VoiceWorkflowExecutionState: Sendable {
    var trace: [VoiceWorkflowTraceEvent] = []
    var timings: [VoiceWorkflowStepTiming] = []
    var degradations: [VoiceWorkflowDegradation] = []
    var activeStep: VoiceWorkflowStep?
}

private struct VoiceWorkflowPipelineValue: Sendable {
    var audio: Data?
    var text: String?
    var providerTranscript: String?
    var rawText: String?
}

private extension VoiceWorkflowEngine {
    func emit(
        _ event: VoiceWorkflowTraceEvent,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async {
        state.trace.append(event)
        await onEvent?(event)
    }

    func finish(
        _ step: VoiceWorkflowStep,
        outcome: VoiceWorkflowStepOutcome,
        duration: TimeInterval,
        input: VoiceWorkflowRunInput,
        workflowID: String,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async {
        state.timings.append(.init(step: step, duration: duration))
        let event = VoiceWorkflowTraceEvent.stepFinished(
            runID: input.runID,
            workflowID: workflowID,
            step: step,
            outcome: outcome,
            duration: duration
        )
        await emit(event, state: &state, onEvent: onEvent)
    }

    func acquireSource(
        _ input: VoiceWorkflowRunInput,
        workflow: ResolvedVoiceWorkflow,
        workflowID: String,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws {
        let step = workflow.source.step
        state.activeStep = step
        let started = VoiceWorkflowTraceEvent.stepStarted(
            runID: input.runID,
            workflowID: workflowID,
            step: step
        )
        await emit(started, state: &state, onEvent: onEvent)

        do {
            try Task.checkCancellation()
        } catch {
            await finish(
                step,
                outcome: .cancelled,
                duration: input.sourceAcquisitionDuration,
                input: input,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )
            throw error
        }

        await finish(
            step,
            outcome: .succeeded,
            duration: input.sourceAcquisitionDuration,
            input: input,
            workflowID: workflowID,
            state: &state,
            onEvent: onEvent
        )
        state.activeStep = nil
    }

    func process(
        _ processors: [ResolvedVoiceWorkflow.Processor],
        input: VoiceWorkflowRunInput,
        workflowID: String,
        value: inout VoiceWorkflowPipelineValue,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws {
        for processor in processors {
            let step = processor.step
            state.activeStep = step
            let started = VoiceWorkflowTraceEvent.stepStarted(
                runID: input.runID,
                workflowID: workflowID,
                step: step
            )
            await emit(started, state: &state, onEvent: onEvent)
            let stepStart = clock.now

            switch processor {
            case .stt(let processor):
                try await processSTT(
                    processor,
                    stepStart: stepStart,
                    input: input,
                    workflowID: workflowID,
                    value: &value,
                    state: &state,
                    onEvent: onEvent
                )
            case .llm(let processor):
                try await processLLM(
                    processor,
                    stepStart: stepStart,
                    input: input,
                    workflowID: workflowID,
                    value: &value,
                    state: &state,
                    onEvent: onEvent
                )
            }
            state.activeStep = nil
        }
    }

    func processSTT(
        _ processor: ResolvedVoiceWorkflow.STTProcessor,
        stepStart: ContinuousClock.Instant,
        input: VoiceWorkflowRunInput,
        workflowID: String,
        value: inout VoiceWorkflowPipelineValue,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws {
        let step = processor.step
        do {
            try Task.checkCancellation()
            guard let inputAudio = value.audio else {
                throw VoiceWorkflowRuntimeError.internalKindMismatch(widgetID: step.widgetID)
            }
            let transcript = try await processor.provider.transcribe(
                audioData: inputAudio,
                language: processor.language,
                vocabulary: processor.vocabulary.terms,
                promptHint: processor.promptHint,
                temperature: processor.temperature
            )
            try Task.checkCancellation()
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceWorkflowRuntimeError.emptyTranscript(widgetID: step.widgetID)
            }
            value.providerTranscript = value.providerTranscript ?? transcript
            let corrected = processor.vocabulary.correct(transcript)
            value.rawText = value.rawText ?? corrected
            value.text = corrected
            value.audio = nil
        } catch {
            let duration = elapsed(since: stepStart)
            let outcome: VoiceWorkflowStepOutcome =
                error is CancellationError || Task.isCancelled ? .cancelled : .failed
            await finish(
                step,
                outcome: outcome,
                duration: duration,
                input: input,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )
            throw error
        }

        await finish(
            step,
            outcome: .succeeded,
            duration: elapsed(since: stepStart),
            input: input,
            workflowID: workflowID,
            state: &state,
            onEvent: onEvent
        )
    }

    func processLLM(
        _ processor: ResolvedVoiceWorkflow.LLMProcessor,
        stepStart: ContinuousClock.Instant,
        input: VoiceWorkflowRunInput,
        workflowID: String,
        value: inout VoiceWorkflowPipelineValue,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws {
        let step = processor.step
        do {
            try Task.checkCancellation()
            guard let inputText = value.text else {
                throw VoiceWorkflowRuntimeError.internalKindMismatch(widgetID: step.widgetID)
            }
            let output = try await processor.provider.process(
                text: inputText,
                configuration: processor.request
            )
            try Task.checkCancellation()
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceWorkflowRuntimeError.emptyLLMResponse(widgetID: step.widgetID)
            }
            value.text = output.trimmingCharacters(in: .whitespacesAndNewlines)

            await finish(
                step,
                outcome: .succeeded,
                duration: elapsed(since: stepStart),
                input: input,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )
        } catch {
            let duration = elapsed(since: stepStart)
            if error is CancellationError || Task.isCancelled {
                await finish(
                    step,
                    outcome: .cancelled,
                    duration: duration,
                    input: input,
                    workflowID: workflowID,
                    state: &state,
                    onEvent: onEvent
                )
                throw CancellationError()
            }

            switch processor.failurePolicy {
            case .useInput:
                state.timings.append(.init(step: step, duration: duration))
                state.degradations.append(.llmFailedUsingInput(widgetID: step.widgetID))
                let event = VoiceWorkflowTraceEvent.stepFinished(
                    runID: input.runID,
                    workflowID: workflowID,
                    step: step,
                    outcome: .fallback,
                    duration: duration
                )
                await emit(event, state: &state, onEvent: onEvent)
            case .failRun:
                await finish(
                    step,
                    outcome: .failed,
                    duration: duration,
                    input: input,
                    workflowID: workflowID,
                    state: &state,
                    onEvent: onEvent
                )
                throw error
            }
        }
    }

    func recordProcessedResult(
        input: VoiceWorkflowRunInput,
        workflowID: String,
        providerTranscript: String,
        rawText: String,
        finalText: String,
        recorder: VoiceWorkflowRunRecorder?,
        state: VoiceWorkflowExecutionState
    ) async throws {
        // Desktop records after processing and before delivery. Keep that
        // ordering so output failures do not discard recoverable text.
        if !input.dryRun, !finalText.isEmpty, let recorder {
            try Task.checkCancellation()
            try await recorder(VoiceWorkflowProcessedResult(
                runID: input.runID,
                workflowID: workflowID,
                providerTranscript: providerTranscript,
                rawText: rawText,
                finalText: finalText,
                degradations: state.degradations,
                timings: VoiceWorkflowTimings(
                    steps: state.timings,
                    total: VoiceWorkflowTimings.processingTotal(state.timings)
                )
            ))
            try Task.checkCancellation()
        }
    }

    func deliver(
        _ outputs: [ResolvedVoiceWorkflow.Output],
        finalText: String,
        input: VoiceWorkflowRunInput,
        workflowID: String,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws {
        for output in outputs {
            let step = output.step
            state.activeStep = step
            let started = VoiceWorkflowTraceEvent.stepStarted(
                runID: input.runID,
                workflowID: workflowID,
                step: step
            )
            await emit(started, state: &state, onEvent: onEvent)
            let stepStart = clock.now

            if input.dryRun {
                await finish(
                    step,
                    outcome: .intercepted,
                    duration: 0,
                    input: input,
                    workflowID: workflowID,
                    state: &state,
                    onEvent: onEvent
                )
                state.activeStep = nil
                continue
            }

            do {
                try Task.checkCancellation()
                try await output.destination.deliver(
                    text: finalText,
                    context: VoiceWorkflowOutputContext(
                        runID: input.runID,
                        workflowID: workflowID,
                        widgetID: output.widget.id
                    )
                )
                try Task.checkCancellation()
            } catch {
                let duration = elapsed(since: stepStart)
                let outcome: VoiceWorkflowStepOutcome =
                    error is CancellationError || Task.isCancelled ? .cancelled : .failed
                await finish(
                    step,
                    outcome: outcome,
                    duration: duration,
                    input: input,
                    workflowID: workflowID,
                    state: &state,
                    onEvent: onEvent
                )
                throw error
            }

            await finish(
                step,
                outcome: .succeeded,
                duration: elapsed(since: stepStart),
                input: input,
                workflowID: workflowID,
                state: &state,
                onEvent: onEvent
            )
            state.activeStep = nil
        }
    }

    func completeRun(
        input: VoiceWorkflowRunInput,
        workflowID: String,
        providerTranscript: String,
        rawText: String,
        finalText: String,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws -> VoiceWorkflowResult {
        // Cancellation requested by the final step observer must not be
        // reported as a successful run.
        try Task.checkCancellation()
        let total = VoiceWorkflowTimings.processingTotal(state.timings)
        let terminal = VoiceWorkflowTraceEvent.runSucceeded(
            runID: input.runID,
            workflowID: workflowID,
            duration: total
        )
        await emit(terminal, state: &state, onEvent: onEvent)
        return VoiceWorkflowResult(
            runID: input.runID,
            workflowID: workflowID,
            providerTranscript: providerTranscript,
            rawText: rawText,
            finalText: finalText,
            degradations: state.degradations,
            timings: VoiceWorkflowTimings(steps: state.timings, total: total),
            trace: state.trace
        )
    }

    func terminateRun(
        after error: any Error,
        input: VoiceWorkflowRunInput,
        workflowID: String,
        state: inout VoiceWorkflowExecutionState,
        onEvent: VoiceWorkflowEventHandler?
    ) async throws -> VoiceWorkflowResult {
        let total = VoiceWorkflowTimings.processingTotal(state.timings)
        if error is CancellationError || Task.isCancelled {
            let terminal = VoiceWorkflowTraceEvent.runCancelled(
                runID: input.runID,
                workflowID: workflowID,
                step: state.activeStep,
                duration: total
            )
            await emit(terminal, state: &state, onEvent: onEvent)
            throw CancellationError()
        }

        let terminal = VoiceWorkflowTraceEvent.runFailed(
            runID: input.runID,
            workflowID: workflowID,
            step: state.activeStep,
            duration: total
        )
        await emit(terminal, state: &state, onEvent: onEvent)
        throw error
    }
}
