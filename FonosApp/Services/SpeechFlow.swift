import Foundation

// MARK: - Provider seams

/// The post-capture Flow only needs this small slice of an LLM provider.
/// Keeping the protocol here lets the runner use production services and
/// deterministic test doubles without reading mutable app configuration.
protocol SpeechFlowLLMProvider: Sendable {
    func process(text: String, mode: Mode, glossary: String?) async throws -> String
}

extension LLMService: SpeechFlowLLMProvider {}

// MARK: - Resolved plan

/// What an optional LLM step should do when its provider fails.
enum SpeechFlowLLMFailurePolicy: Equatable, Sendable {
    /// Complete the run with the text that entered the LLM step.
    case useInput
    /// Fail the entire run and preserve the provider error.
    case failRun
}

/// Why a resolved Flow intentionally contains no LLM step.
enum SpeechFlowLLMSkipReason: Equatable, Sendable {
    case notRequested
    case notConfigured
}

/// Immutable vocabulary resolved for one run. Book order is significant:
/// global books precede scoped books, and rules run in book order.
struct SpeechFlowVocabSnapshot: Equatable, Sendable {
    let effectiveBooks: [VocabBook]
    let terms: [String]

    init(effectiveBooks: [VocabBook]) {
        self.effectiveBooks = effectiveBooks
        self.terms = VocabApplier.collectTerms(effectiveBooks)
    }

    init(context: VocabStore.Context) {
        self.effectiveBooks = context.books
        self.terms = context.terms
    }

    func correct(_ text: String) -> String {
        VocabApplier.applyRules(text, books: effectiveBooks)
    }

    var glossary: String? {
        VocabApplier.buildGlossaryBlock(terms: terms)
    }
}

/// A fully resolved, in-memory post-capture Flow.
///
/// This is deliberately not a persisted, user-editable workflow definition.
/// It freezes provider instances and configuration before the first await so a
/// settings change cannot alter the middle of a run.
struct ResolvedSpeechFlow: Sendable {
    struct STTStep: Sendable {
        let provider: any STTProvider
        let language: String?
        let promptHint: String
    }

    struct LLMStep: Sendable {
        let provider: any SpeechFlowLLMProvider
        let mode: Mode
        let failurePolicy: SpeechFlowLLMFailurePolicy
    }

    enum Postprocess: Sendable {
        case none(SpeechFlowLLMSkipReason)
        case llm(LLMStep)
    }

    let flowID: String
    let stt: STTStep
    let vocab: SpeechFlowVocabSnapshot
    let postprocess: Postprocess
}

struct SpeechFlowInput: Sendable {
    let runID: UUID
    let wavData: Data

    init(runID: UUID = UUID(), wavData: Data) {
        self.runID = runID
        self.wavData = wavData
    }
}

// MARK: - Result contract

enum SpeechFlowLLMOutcome: Equatable, Sendable {
    case skipped(SpeechFlowLLMSkipReason)
    case succeeded
    case fellBackToInput

    var isFallback: Bool {
        self == .fellBackToInput
    }

    var producedProcessedText: Bool {
        self == .succeeded
    }
}

enum SpeechFlowDegradation: Equatable, Sendable {
    case llmFailedUsingInput
}

struct SpeechFlowTimings: Equatable, Sendable {
    let stt: TimeInterval
    let vocabCorrection: TimeInterval
    let llm: TimeInterval?
    let total: TimeInterval

    static let zero = SpeechFlowTimings(
        stt: 0,
        vocabCorrection: 0,
        llm: nil,
        total: 0
    )
}

struct SpeechFlowResult: Sendable {
    let runID: UUID
    let flowID: String

    /// Text exactly as returned by the STT provider.
    let providerTranscript: String
    /// Text after deterministic vocabulary rules; this is the LLM input.
    let correctedTranscript: String
    /// Processed text, or `correctedTranscript` when no LLM result is used.
    let finalText: String

    let llmOutcome: SpeechFlowLLMOutcome
    let degradation: SpeechFlowDegradation?
    let timings: SpeechFlowTimings
    let events: [SpeechFlowEvent]
}

// MARK: - Privacy-safe trace events

enum SpeechFlowStep: String, Equatable, Sendable {
    case stt
    case vocabCorrection
    case llm
}

enum SpeechFlowStepOutcome: Equatable, Sendable {
    case succeeded
    case fallback
    case failed
    case cancelled
}

/// Structural trace event. It intentionally carries no transcript, prompt,
/// glossary, or provider response body.
enum SpeechFlowEvent: Equatable, Sendable {
    case runStarted(runID: UUID, flowID: String)
    case stepStarted(runID: UUID, step: SpeechFlowStep)
    case stepFinished(
        runID: UUID,
        step: SpeechFlowStep,
        outcome: SpeechFlowStepOutcome,
        duration: TimeInterval
    )
    case runSucceeded(runID: UUID, duration: TimeInterval)
    case runFailed(runID: UUID, step: SpeechFlowStep, duration: TimeInterval)
    case runCancelled(runID: UUID, step: SpeechFlowStep?, duration: TimeInterval)
}

typealias SpeechFlowEventHandler = @Sendable (SpeechFlowEvent) async -> Void

// MARK: - UI presentation state

/// A privacy-safe, value-only projection of one Flow run for SwiftUI.
/// It intentionally contains no transcript, prompt, glossary, or provider response.
struct SpeechFlowPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case running(current: SpeechFlowStep?)
        case succeeded
        case degraded
        case failed(step: SpeechFlowStep)
        case cancelled
    }

    enum StepState: Equatable, Sendable {
        case pending
        case running
        case succeeded(duration: TimeInterval)
        case fallback(duration: TimeInterval)
        case failed(duration: TimeInterval)
        case cancelled(duration: TimeInterval)
        case skipped(SpeechFlowLLMSkipReason)
    }

    struct Step: Equatable, Sendable {
        let id: SpeechFlowStep
        var state: StepState
    }

    var runID: UUID?
    var flowID: String?
    var phase: Phase
    var steps: [Step]
    var llmOutcome: SpeechFlowLLMOutcome?
    var degradation: SpeechFlowDegradation?
    var timings: SpeechFlowTimings?

    static let idle = SpeechFlowPresentation(
        runID: nil,
        flowID: nil,
        phase: .idle,
        steps: [],
        llmOutcome: nil,
        degradation: nil,
        timings: nil
    )

    init(runID: UUID, flow: ResolvedSpeechFlow) {
        let llmState: StepState
        let initialOutcome: SpeechFlowLLMOutcome?
        switch flow.postprocess {
        case .none(let reason):
            llmState = .skipped(reason)
            initialOutcome = .skipped(reason)
        case .llm:
            llmState = .pending
            initialOutcome = nil
        }

        self.runID = runID
        self.flowID = flow.flowID
        self.phase = .running(current: nil)
        self.steps = [
            Step(id: .stt, state: .pending),
            Step(id: .vocabCorrection, state: .pending),
            Step(id: .llm, state: llmState)
        ]
        self.llmOutcome = initialOutcome
        self.degradation = nil
        self.timings = nil
    }

    private init(
        runID: UUID?,
        flowID: String?,
        phase: Phase,
        steps: [Step],
        llmOutcome: SpeechFlowLLMOutcome?,
        degradation: SpeechFlowDegradation?,
        timings: SpeechFlowTimings?
    ) {
        self.runID = runID
        self.flowID = flowID
        self.phase = phase
        self.steps = steps
        self.llmOutcome = llmOutcome
        self.degradation = degradation
        self.timings = timings
    }

    var currentStep: SpeechFlowStep? {
        guard case .running(let current) = phase else { return nil }
        return current
    }

    func state(for step: SpeechFlowStep) -> StepState? {
        steps.first(where: { $0.id == step })?.state
    }

    /// Reduces a structural runner event. Events from older runs and events
    /// arriving after a terminal state are ignored.
    mutating func apply(_ event: SpeechFlowEvent) {
        guard let runID, event.runID == runID else { return }
        guard !phase.isTerminal else { return }

        switch event {
        case .runStarted:
            phase = .running(current: nil)

        case .stepStarted(_, let step):
            update(step, to: .running)
            phase = .running(current: step)

        case .stepFinished(_, let step, let outcome, let duration):
            let state: StepState
            switch outcome {
            case .succeeded: state = .succeeded(duration: duration)
            case .fallback: state = .fallback(duration: duration)
            case .failed: state = .failed(duration: duration)
            case .cancelled: state = .cancelled(duration: duration)
            }
            update(step, to: state)
            phase = .running(current: nil)

        case .runSucceeded(_, let duration):
            phase = steps.contains(where: { step in
                if case .fallback = step.state { return true }
                return false
            }) ? .degraded : .succeeded
            setTotalDuration(duration)

        case .runFailed(_, let step, let duration):
            phase = .failed(step: step)
            setTotalDuration(duration)

        case .runCancelled(_, _, let duration):
            phase = .cancelled
            setTotalDuration(duration)
        }
    }

    /// Completes the projection with the semantic outcome and authoritative
    /// timings returned by the runner.
    mutating func complete(
        llmOutcome: SpeechFlowLLMOutcome,
        degradation: SpeechFlowDegradation?,
        timings: SpeechFlowTimings
    ) {
        guard runID != nil else { return }
        self.llmOutcome = llmOutcome
        self.degradation = degradation
        self.timings = timings

        switch llmOutcome {
        case .skipped(let reason):
            update(.llm, to: .skipped(reason))
        case .succeeded:
            update(.llm, to: .succeeded(duration: timings.llm ?? 0))
        case .fellBackToInput:
            update(.llm, to: .fallback(duration: timings.llm ?? 0))
        }

        phase = degradation == nil ? .succeeded : .degraded
    }

    private mutating func update(_ step: SpeechFlowStep, to state: StepState) {
        guard let index = steps.firstIndex(where: { $0.id == step }) else { return }
        steps[index].state = state
    }

    private mutating func setTotalDuration(_ duration: TimeInterval) {
        let current = timings ?? .zero
        timings = SpeechFlowTimings(
            stt: current.stt,
            vocabCorrection: current.vocabCorrection,
            llm: current.llm,
            total: duration
        )
    }
}

extension SpeechFlowEvent {
    var runID: UUID {
        switch self {
        case .runStarted(let runID, _),
             .stepStarted(let runID, _),
             .stepFinished(let runID, _, _, _),
             .runSucceeded(let runID, _),
             .runFailed(let runID, _, _),
             .runCancelled(let runID, _, _):
            return runID
        }
    }
}

private extension SpeechFlowPresentation.Phase {
    var isTerminal: Bool {
        switch self {
        case .idle, .running:
            return false
        case .succeeded, .degraded, .failed, .cancelled:
            return true
        }
    }
}
