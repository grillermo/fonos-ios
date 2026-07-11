import Foundation

/// Executes the fixed iOS post-capture algebra:
/// STT -> vocabulary correction -> optional LLM.
struct SpeechFlowRunner: Sendable {
    private let clock = ContinuousClock()

    func run(
        _ input: SpeechFlowInput,
        using flow: ResolvedSpeechFlow,
        onEvent: SpeechFlowEventHandler? = nil
    ) async throws -> SpeechFlowResult {
        var events: [SpeechFlowEvent] = []

        let runStarted = SpeechFlowEvent.runStarted(
            runID: input.runID,
            flowID: flow.flowID
        )
        events.append(runStarted)
        await publish(runStarted, to: onEvent)
        // Observer back-pressure is not provider execution time.
        let runStartedAt = clock.now

        if Task.isCancelled {
            let duration = elapsed(since: runStartedAt)
            let event = SpeechFlowEvent.runCancelled(
                runID: input.runID,
                step: nil,
                duration: duration
            )
            events.append(event)
            await publish(event, to: onEvent)
            throw CancellationError()
        }

        // MARK: STT

        let sttStarted = SpeechFlowEvent.stepStarted(
            runID: input.runID,
            step: .stt
        )
        events.append(sttStarted)
        await publish(sttStarted, to: onEvent)
        let sttStartedAt = clock.now

        let providerTranscript: String
        let sttDuration: TimeInterval
        do {
            providerTranscript = try await flow.stt.provider.transcribe(
                audioData: input.wavData,
                language: flow.stt.language,
                vocabulary: flow.vocab.terms,
                promptHint: flow.stt.promptHint
            )
            try Task.checkCancellation()
            guard !providerTranscript.isEmpty else {
                throw STTError.noTranscript
            }
            sttDuration = elapsed(since: sttStartedAt)
        } catch {
            let stepDuration = elapsed(since: sttStartedAt)
            if error is CancellationError || Task.isCancelled {
                let stepEvent = SpeechFlowEvent.stepFinished(
                    runID: input.runID,
                    step: .stt,
                    outcome: .cancelled,
                    duration: stepDuration
                )
                events.append(stepEvent)
                await publish(stepEvent, to: onEvent)

                let terminal = SpeechFlowEvent.runCancelled(
                    runID: input.runID,
                    step: .stt,
                    duration: elapsed(since: runStartedAt)
                )
                events.append(terminal)
                await publish(terminal, to: onEvent)
                throw CancellationError()
            }

            let stepEvent = SpeechFlowEvent.stepFinished(
                runID: input.runID,
                step: .stt,
                outcome: .failed,
                duration: stepDuration
            )
            events.append(stepEvent)
            await publish(stepEvent, to: onEvent)

            let terminal = SpeechFlowEvent.runFailed(
                runID: input.runID,
                step: .stt,
                duration: elapsed(since: runStartedAt)
            )
            events.append(terminal)
            await publish(terminal, to: onEvent)
            throw error
        }

        let sttFinished = SpeechFlowEvent.stepFinished(
            runID: input.runID,
            step: .stt,
            outcome: .succeeded,
            duration: sttDuration
        )
        events.append(sttFinished)
        await publish(sttFinished, to: onEvent)

        // MARK: Vocabulary correction

        if Task.isCancelled {
            let terminal = SpeechFlowEvent.runCancelled(
                runID: input.runID,
                step: nil,
                duration: elapsed(since: runStartedAt)
            )
            events.append(terminal)
            await publish(terminal, to: onEvent)
            throw CancellationError()
        }

        let correctionStarted = SpeechFlowEvent.stepStarted(
            runID: input.runID,
            step: .vocabCorrection
        )
        events.append(correctionStarted)
        await publish(correctionStarted, to: onEvent)
        let correctionStartedAt = clock.now

        let correctedTranscript = flow.vocab.correct(providerTranscript)
        let correctionDuration = elapsed(since: correctionStartedAt)

        if Task.isCancelled {
            let stepEvent = SpeechFlowEvent.stepFinished(
                runID: input.runID,
                step: .vocabCorrection,
                outcome: .cancelled,
                duration: correctionDuration
            )
            events.append(stepEvent)
            await publish(stepEvent, to: onEvent)

            let terminal = SpeechFlowEvent.runCancelled(
                runID: input.runID,
                step: .vocabCorrection,
                duration: elapsed(since: runStartedAt)
            )
            events.append(terminal)
            await publish(terminal, to: onEvent)
            throw CancellationError()
        }

        let correctionFinished = SpeechFlowEvent.stepFinished(
            runID: input.runID,
            step: .vocabCorrection,
            outcome: .succeeded,
            duration: correctionDuration
        )
        events.append(correctionFinished)
        await publish(correctionFinished, to: onEvent)

        // MARK: Optional LLM

        let finalText: String
        let llmOutcome: SpeechFlowLLMOutcome
        let degradation: SpeechFlowDegradation?
        var llmDuration: TimeInterval?

        switch flow.postprocess {
        case .none(let reason):
            finalText = correctedTranscript
            llmOutcome = .skipped(reason)
            degradation = nil

        case .llm(let step):
            if Task.isCancelled {
                let terminal = SpeechFlowEvent.runCancelled(
                    runID: input.runID,
                    step: nil,
                    duration: elapsed(since: runStartedAt)
                )
                events.append(terminal)
                await publish(terminal, to: onEvent)
                throw CancellationError()
            }

            let llmStarted = SpeechFlowEvent.stepStarted(
                runID: input.runID,
                step: .llm
            )
            events.append(llmStarted)
            await publish(llmStarted, to: onEvent)
            let llmStartedAt = clock.now

            do {
                let processedText = try await step.provider.process(
                    text: correctedTranscript,
                    mode: step.mode,
                    glossary: flow.vocab.glossary
                )
                try Task.checkCancellation()
                finalText = processedText
                llmDuration = elapsed(since: llmStartedAt)
                llmOutcome = .succeeded
                degradation = nil

                let llmFinished = SpeechFlowEvent.stepFinished(
                    runID: input.runID,
                    step: .llm,
                    outcome: .succeeded,
                    duration: llmDuration ?? 0
                )
                events.append(llmFinished)
                await publish(llmFinished, to: onEvent)
            } catch {
                let stepDuration = elapsed(since: llmStartedAt)
                llmDuration = stepDuration

                if error is CancellationError || Task.isCancelled {
                    let stepEvent = SpeechFlowEvent.stepFinished(
                        runID: input.runID,
                        step: .llm,
                        outcome: .cancelled,
                        duration: stepDuration
                    )
                    events.append(stepEvent)
                    await publish(stepEvent, to: onEvent)

                    let terminal = SpeechFlowEvent.runCancelled(
                        runID: input.runID,
                        step: .llm,
                        duration: elapsed(since: runStartedAt)
                    )
                    events.append(terminal)
                    await publish(terminal, to: onEvent)
                    throw CancellationError()
                }

                switch step.failurePolicy {
                case .useInput:
                    finalText = correctedTranscript
                    llmOutcome = .fellBackToInput
                    degradation = .llmFailedUsingInput

                    let stepEvent = SpeechFlowEvent.stepFinished(
                        runID: input.runID,
                        step: .llm,
                        outcome: .fallback,
                        duration: stepDuration
                    )
                    events.append(stepEvent)
                    await publish(stepEvent, to: onEvent)

                case .failRun:
                    let stepEvent = SpeechFlowEvent.stepFinished(
                        runID: input.runID,
                        step: .llm,
                        outcome: .failed,
                        duration: stepDuration
                    )
                    events.append(stepEvent)
                    await publish(stepEvent, to: onEvent)

                    let terminal = SpeechFlowEvent.runFailed(
                        runID: input.runID,
                        step: .llm,
                        duration: elapsed(since: runStartedAt)
                    )
                    events.append(terminal)
                    await publish(terminal, to: onEvent)
                    throw error
                }
            }
        }

        if Task.isCancelled {
            let terminal = SpeechFlowEvent.runCancelled(
                runID: input.runID,
                step: nil,
                duration: elapsed(since: runStartedAt)
            )
            events.append(terminal)
            await publish(terminal, to: onEvent)
            throw CancellationError()
        }

        // Successful-run metrics describe Flow work, not UI/event observer back-pressure.
        let totalDuration = sttDuration + correctionDuration + (llmDuration ?? 0)
        let terminal = SpeechFlowEvent.runSucceeded(
            runID: input.runID,
            duration: totalDuration
        )
        events.append(terminal)
        await publish(terminal, to: onEvent)

        return SpeechFlowResult(
            runID: input.runID,
            flowID: flow.flowID,
            providerTranscript: providerTranscript,
            correctedTranscript: correctedTranscript,
            finalText: finalText,
            llmOutcome: llmOutcome,
            degradation: degradation,
            timings: SpeechFlowTimings(
                stt: sttDuration,
                vocabCorrection: correctionDuration,
                llm: llmDuration,
                total: totalDuration
            ),
            events: events
        )
    }

    private func publish(
        _ event: SpeechFlowEvent,
        to handler: SpeechFlowEventHandler?
    ) async {
        await handler?(event)
    }

    private func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        let components = start.duration(to: clock.now).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
