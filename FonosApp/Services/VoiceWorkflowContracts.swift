import Foundation

// MARK: - Provider and output seams

/// The workflow engine's small LLM surface. Production uses `LLMService`;
/// tests can inject a deterministic actor without constructing HTTP requests.
protocol VoiceWorkflowLLMProvider: Sendable {
    func process(text: String, configuration: LLMRequestConfiguration) async throws -> String
}

extension LLMService: VoiceWorkflowLLMProvider {}

struct VoiceWorkflowOutputContext: Equatable, Sendable {
    let runID: UUID
    let workflowID: String
    let widgetID: String
}

/// A resolved output destination. Resolution happens while compiling, before
/// any source or processor is invoked.
protocol VoiceWorkflowOutput: Sendable {
    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws
}

/// iOS interpretation of desktop `out.insert` and `out.return`: the engine's
/// result is returned to the calling surface, which owns UI/keyboard delivery.
struct ReturnToCallerVoiceWorkflowOutput: VoiceWorkflowOutput {
    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {}
}

// MARK: - Frozen runtime resolution

struct ResolvedVoiceWorkflowSTT: Sendable {
    let provider: any STTProvider
}

struct ResolvedVoiceWorkflowLLM: Sendable {
    let provider: any VoiceWorkflowLLMProvider
    let translateTarget: String

    init(
        provider: any VoiceWorkflowLLMProvider,
        translateTarget: String = "English"
    ) {
        self.provider = provider
        self.translateTarget = translateTarget
    }
}

/// Synchronous resolvers are called exactly once per referenced component at
/// compile time. The resulting providers, request parameters, vocab books and
/// output adapters are immutable for the lifetime of the plan.
struct VoiceWorkflowRuntimeResolver: Sendable {
    let resolveSTT: @Sendable (WorkflowWidget) throws -> ResolvedVoiceWorkflowSTT
    let resolveLLM: @Sendable (WorkflowWidget) throws -> ResolvedVoiceWorkflowLLM
    let resolveVocabulary: @Sendable (String, WorkflowWidget) throws -> VoiceWorkflowVocabulary
    let resolveOutput: @Sendable (WorkflowWidget) throws -> any VoiceWorkflowOutput

    init(
        resolveSTT: @escaping @Sendable (WorkflowWidget) throws -> ResolvedVoiceWorkflowSTT,
        resolveLLM: @escaping @Sendable (WorkflowWidget) throws -> ResolvedVoiceWorkflowLLM,
        resolveVocabulary: @escaping @Sendable (String, WorkflowWidget) throws -> VoiceWorkflowVocabulary = { _, _ in
            VoiceWorkflowVocabulary(effectiveBooks: [])
        },
        resolveOutput: @escaping @Sendable (WorkflowWidget) throws -> any VoiceWorkflowOutput
    ) {
        self.resolveSTT = resolveSTT
        self.resolveLLM = resolveLLM
        self.resolveVocabulary = resolveVocabulary
        self.resolveOutput = resolveOutput
    }
}

// MARK: - Validation and compile contracts

enum VoiceWorkflowSourceKind: String, Equatable, Sendable {
    case microphone
    case providedAudio = "provided_audio"
}

enum VoiceWorkflowLLMFailurePolicy: String, Equatable, Sendable {
    case useInput = "use_input"
    case failRun = "fail_run"
}

struct VoiceWorkflowStep: Equatable, Sendable {
    let index: Int
    let widgetID: String
    let role: WorkflowRole
    let typeTag: String
}

struct VoiceWorkflowValidation: Equatable, Sendable {
    let workflowID: String
    let sourceKind: VoiceWorkflowSourceKind
    let steps: [VoiceWorkflowStep]
    let finalKind: WorkflowDataKind
}

enum VoiceWorkflowCompileError: LocalizedError, Equatable, Sendable {
    case noOutputs(workflowID: String)
    case unknownWidget(workflowID: String, widgetID: String)
    case ambiguousWidgetID(widgetID: String)
    case roleMismatch(widgetID: String, expected: WorkflowRole, actual: WorkflowRole)
    case unsupportedWidget(widgetID: String, role: WorkflowRole, typeTag: String)
    case kindMismatch(widgetID: String, expected: WorkflowDataKind, actual: WorkflowDataKind)
    case finalKindMustBeText(actual: WorkflowDataKind)
    case invalidProperty(widgetID: String, key: String, reason: String)
    case resolutionFailed(widgetID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noOutputs(let workflowID):
            "Workflow '\(workflowID)' must declare at least one output."
        case .unknownWidget(let workflowID, let widgetID):
            "Workflow '\(workflowID)' references unknown widget '\(widgetID)'."
        case .ambiguousWidgetID(let widgetID):
            "Widget id '\(widgetID)' is duplicated."
        case .roleMismatch(let widgetID, let expected, let actual):
            "Widget '\(widgetID)' has role \(actual), expected \(expected)."
        case .unsupportedWidget(let widgetID, let role, let typeTag):
            "Widget '\(widgetID)' uses unsupported \(role) type '\(typeTag)'."
        case .kindMismatch(let widgetID, let expected, let actual):
            "Widget '\(widgetID)' requires \(expected.rawValue) but receives \(actual.rawValue)."
        case .finalKindMustBeText(let actual):
            "Voice workflow ends in \(actual.rawValue); outputs require text."
        case .invalidProperty(let widgetID, let key, let reason):
            "Widget '\(widgetID)' has invalid '\(key)': \(reason)."
        case .resolutionFailed(let widgetID, let reason):
            "Could not resolve widget '\(widgetID)': \(reason)."
        }
    }
}

enum VoiceWorkflowRuntimeError: LocalizedError, Equatable, Sendable {
    case sourceInputMismatch(expected: VoiceWorkflowSourceKind, actual: VoiceWorkflowSourceKind)
    case emptyTranscript(widgetID: String)
    case emptyLLMResponse(widgetID: String)
    case internalKindMismatch(widgetID: String)

    var errorDescription: String? {
        switch self {
        case .sourceInputMismatch(let expected, let actual):
            "Workflow expects \(expected.rawValue) input, received \(actual.rawValue)."
        case .emptyTranscript(let widgetID):
            "STT widget '\(widgetID)' returned no transcript."
        case .emptyLLMResponse(let widgetID):
            "LLM widget '\(widgetID)' returned an empty response."
        case .internalKindMismatch(let widgetID):
            "Workflow data did not match the compiled kind at '\(widgetID)'."
        }
    }
}

// MARK: - Trace and result contracts

enum VoiceWorkflowStepOutcome: Equatable, Sendable {
    case succeeded
    case fallback
    case failed
    case cancelled
    case intercepted
}

/// Privacy-safe structural trace. No case contains audio, transcript, prompt,
/// glossary, provider response, API key or raw error text.
enum VoiceWorkflowTraceEvent: Equatable, Sendable {
    case runStarted(runID: UUID, workflowID: String)
    case stepStarted(runID: UUID, workflowID: String, step: VoiceWorkflowStep)
    case stepFinished(
        runID: UUID,
        workflowID: String,
        step: VoiceWorkflowStep,
        outcome: VoiceWorkflowStepOutcome,
        duration: TimeInterval
    )
    case runSucceeded(runID: UUID, workflowID: String, duration: TimeInterval)
    case runFailed(runID: UUID, workflowID: String, step: VoiceWorkflowStep?, duration: TimeInterval)
    case runCancelled(runID: UUID, workflowID: String, step: VoiceWorkflowStep?, duration: TimeInterval)

    var isTerminal: Bool {
        switch self {
        case .runSucceeded, .runFailed, .runCancelled: true
        case .runStarted, .stepStarted, .stepFinished: false
        }
    }
}

typealias VoiceWorkflowEventHandler = @Sendable (VoiceWorkflowTraceEvent) async -> Void

/// Processor result handed to the run recorder before any output delivery,
/// matching fonos-core's recorder placement. This lets History retain
/// recoverable text even when a clipboard/app route later fails.
struct VoiceWorkflowProcessedResult: Equatable, Sendable {
    let runID: UUID
    let workflowID: String
    let providerTranscript: String
    let rawText: String
    let finalText: String
    let degradations: [VoiceWorkflowDegradation]
    let timings: VoiceWorkflowTimings
}

typealias VoiceWorkflowRunRecorder = @Sendable (VoiceWorkflowProcessedResult) async throws -> Void

struct VoiceWorkflowStepTiming: Equatable, Sendable {
    let step: VoiceWorkflowStep
    let duration: TimeInterval
}

struct VoiceWorkflowTimings: Equatable, Sendable {
    let steps: [VoiceWorkflowStepTiming]
    /// End-to-end processing and delivery latency after the input envelope is
    /// available. Microphone capture is still retained as a source-step timing
    /// for diagnostics, but is deliberately excluded from this user-facing
    /// total: a 30-second recording must not look like 30 seconds of latency.
    let total: TimeInterval

    func duration(forWidgetID widgetID: String) -> TimeInterval? {
        let matching = steps.filter { $0.step.widgetID == widgetID }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.duration }
    }

    static func processingTotal(_ steps: [VoiceWorkflowStepTiming]) -> TimeInterval {
        steps.lazy
            .filter { $0.step.role != .source }
            .reduce(0) { $0 + $1.duration }
    }
}

enum VoiceWorkflowDegradation: Equatable, Sendable {
    case llmFailedUsingInput(widgetID: String)
}

struct VoiceWorkflowResult: Equatable, Sendable {
    let runID: UUID
    let workflowID: String
    /// Exact provider transcript before deterministic vocabulary correction.
    let providerTranscript: String
    /// First text produced by the pipeline: STT output after its frozen vocab
    /// correction. This matches desktop `RunOutcome.raw_text` and is the first
    /// LLM widget's input.
    let rawText: String
    /// Text after every processor; this is what outputs received.
    let finalText: String
    let degradations: [VoiceWorkflowDegradation]
    let timings: VoiceWorkflowTimings
    let trace: [VoiceWorkflowTraceEvent]
}

struct VoiceWorkflowRunInput: Equatable, Sendable {
    let runID: UUID
    let audioData: Data
    let source: VoiceWorkflowSourceKind
    /// Time spent by the platform surface acquiring the source before the
    /// engine received its immutable audio envelope.
    let sourceAcquisitionDuration: TimeInterval
    let dryRun: Bool

    init(
        runID: UUID = UUID(),
        audioData: Data,
        source: VoiceWorkflowSourceKind = .microphone,
        sourceAcquisitionDuration: TimeInterval = 0,
        dryRun: Bool = false
    ) {
        self.runID = runID
        self.audioData = audioData
        self.source = source
        self.sourceAcquisitionDuration = max(0, sourceAcquisitionDuration)
        self.dryRun = dryRun
    }
}

// MARK: - Resolved plan

struct ResolvedVoiceWorkflow: Sendable {
    struct Source: Sendable {
        let widget: WorkflowWidget
        let kind: VoiceWorkflowSourceKind
        let step: VoiceWorkflowStep
    }

    struct STTProcessor: Sendable {
        let widget: WorkflowWidget
        let step: VoiceWorkflowStep
        let provider: any STTProvider
        let language: String?
        let promptHint: String
        let temperature: Double
        let vocabulary: VoiceWorkflowVocabulary
    }

    struct LLMProcessor: Sendable {
        let widget: WorkflowWidget
        let step: VoiceWorkflowStep
        let provider: any VoiceWorkflowLLMProvider
        let request: LLMRequestConfiguration
        let failurePolicy: VoiceWorkflowLLMFailurePolicy
    }

    enum Processor: Sendable {
        case stt(STTProcessor)
        case llm(LLMProcessor)

        var step: VoiceWorkflowStep {
            switch self {
            case .stt(let value): value.step
            case .llm(let value): value.step
            }
        }
    }

    struct Output: Sendable {
        let widget: WorkflowWidget
        let step: VoiceWorkflowStep
        let destination: any VoiceWorkflowOutput
    }

    let definition: WorkflowDefinition
    let validation: VoiceWorkflowValidation
    let source: Source
    let processors: [Processor]
    let outputs: [Output]
}
