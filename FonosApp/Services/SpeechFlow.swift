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
