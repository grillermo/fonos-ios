import Foundation
import SwiftUI
import SwiftData
import os.log

private let log = Logger(subsystem: "com.fonos.ios", category: "DictationViewModel")

// MARK: - DictationError

/// Errors thrown by DictationViewModel.
enum DictationError: LocalizedError, Equatable {
    case noSTTProviderConfigured
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSTTProviderConfigured:
            "No speech-to-text provider is configured. Please configure one in Settings."
        case .transcriptionFailed(let reason):
            "Transcription failed: \(reason)"
        }
    }
}

// MARK: - ProcessResult

/// The result of audio processing (STT + optional LLM).
struct ProcessResult: Sendable {
    /// The processed or raw text.
    let text: String
    /// The deterministically corrected STT transcript passed to the LLM.
    /// Kept under the legacy name for UI and History compatibility.
    let rawTranscript: String
    /// Text exactly as returned by the STT provider, before vocab correction.
    let providerTranscript: String
    /// True if LLM processing failed and we used the corrected transcript.
    let isRawFallback: Bool
    /// True only when an LLM produced the final text.
    let didProcessWithLLM: Bool
    /// Canonical workflow degradations, including a missing or failed LLM
    /// whose `use_input` policy preserved the incoming text.
    let degradations: [VoiceWorkflowDegradation]
    let timings: VoiceWorkflowTimings

    init(text: String,
         rawTranscript: String? = nil,
         isRawFallback: Bool = false,
         providerTranscript: String? = nil,
         didProcessWithLLM: Bool = false,
         degradations: [VoiceWorkflowDegradation] = [],
         timings: VoiceWorkflowTimings = .init(steps: [], total: 0)) {
        self.text = text
        self.rawTranscript = rawTranscript ?? text
        self.providerTranscript = providerTranscript ?? rawTranscript ?? text
        self.isRawFallback = isRawFallback
        self.didProcessWithLLM = didProcessWithLLM
        self.degradations = degradations
        self.timings = timings
    }
}

private struct LegacyVoiceWorkflowLLMAdapter: VoiceWorkflowLLMProvider {
    let provider: any LegacyModeLLMProvider
    let mode: Mode
    let glossary: String?

    func process(text: String, configuration: LLMRequestConfiguration) async throws -> String {
        try await provider.process(text: text, mode: mode, glossary: glossary)
    }
}

private struct TextDestinationVoiceWorkflowOutput: VoiceWorkflowOutput {
    let destination: AnyTextDestination

    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {
        try await destination.send(text: text)
    }
}

// MARK: - Workflow presentation

/// A privacy-safe projection of the actual recipe being executed. Nodes come
/// from `WorkflowDefinition` rather than a hard-coded STT/vocabulary/LLM list,
/// so fan-out outputs and recipes without an LLM remain truthful in the UI.
struct WorkflowRunPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case running
        case succeeded
        case degraded
        case failed
        case cancelled
    }

    enum NodeState: Equatable, Sendable {
        case pending
        case running
        case succeeded(duration: TimeInterval)
        case fallback(duration: TimeInterval)
        case failed(duration: TimeInterval)
        case cancelled(duration: TimeInterval)
        case intercepted
    }

    struct Node: Identifiable, Equatable, Sendable {
        let index: Int
        let widgetID: String
        let role: WorkflowRole
        let typeTag: String
        let name: String
        let icon: String
        var state: NodeState

        var id: String { "\(index):\(widgetID)" }
    }

    var runID: UUID?
    var workflowID: String?
    var workflowName: String?
    var phase: Phase
    var nodes: [Node]
    var totalDuration: TimeInterval?

    private init(
        runID: UUID?,
        workflowID: String?,
        workflowName: String?,
        phase: Phase,
        nodes: [Node],
        totalDuration: TimeInterval?
    ) {
        self.runID = runID
        self.workflowID = workflowID
        self.workflowName = workflowName
        self.phase = phase
        self.nodes = nodes
        self.totalDuration = totalDuration
    }

    static let idle = WorkflowRunPresentation(
        runID: nil,
        workflowID: nil,
        workflowName: nil,
        phase: .idle,
        nodes: [],
        totalDuration: nil
    )

    static func preview(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog
    ) -> WorkflowRunPresentation {
        var value = WorkflowRunPresentation(
            runID: UUID(),
            definition: definition,
            catalog: catalog
        )
        value.runID = nil
        value.phase = .idle
        return value
    }

    init(runID: UUID, definition: WorkflowDefinition, catalog: WorkflowCatalog) {
        let componentIDs = [definition.source] + definition.processors + definition.outputs
        let processorEnd = definition.processors.count
        self.runID = runID
        self.workflowID = definition.id
        self.workflowName = definition.name
        self.phase = .running
        self.nodes = componentIDs.enumerated().map { index, widgetID in
            let role: WorkflowRole
            if index == 0 {
                role = .source
            } else if index <= processorEnd {
                role = .processor
            } else {
                role = .output
            }
            let widget = catalog.widget(id: widgetID)
            let adaptedName: String
            if role == .output, widget?.typeTag == "insert" {
                adaptedName = String(localized: "Return to app (adapted)")
            } else {
                adaptedName = widget?.name ?? widgetID
            }
            return Node(
                index: index,
                widgetID: widgetID,
                role: role,
                typeTag: widget?.typeTag ?? "unknown",
                name: adaptedName,
                icon: widget?.icon ?? "questionmark",
                state: .pending
            )
        }
        self.totalDuration = nil
    }

    mutating func apply(_ event: VoiceWorkflowTraceEvent) {
        let eventIdentity: (UUID, String)
        switch event {
        case .runStarted(let runID, let workflowID),
             .stepStarted(let runID, let workflowID, _),
             .stepFinished(let runID, let workflowID, _, _, _),
             .runSucceeded(let runID, let workflowID, _),
             .runFailed(let runID, let workflowID, _, _),
             .runCancelled(let runID, let workflowID, _, _):
            eventIdentity = (runID, workflowID)
        }
        guard eventIdentity.0 == runID, eventIdentity.1 == workflowID else { return }
        guard !phase.isTerminal else { return }

        switch event {
        case .runStarted:
            phase = .running
        case .stepStarted(_, _, let step):
            update(step: step, state: .running)
        case .stepFinished(_, _, let step, let outcome, let duration):
            let state: NodeState
            switch outcome {
            case .succeeded: state = .succeeded(duration: duration)
            case .fallback: state = .fallback(duration: duration)
            case .failed: state = .failed(duration: duration)
            case .cancelled: state = .cancelled(duration: duration)
            case .intercepted: state = .intercepted
            }
            update(step: step, state: state)
        case .runSucceeded(_, _, let duration):
            totalDuration = duration
            phase = nodes.contains(where: {
                if case .fallback = $0.state { return true }
                return false
            }) ? .degraded : .succeeded
        case .runFailed(_, _, _, let duration):
            totalDuration = duration
            phase = .failed
        case .runCancelled(_, _, _, let duration):
            totalDuration = duration
            phase = .cancelled
        }
    }

    mutating func complete(with result: VoiceWorkflowResult) {
        guard result.runID == runID, result.workflowID == workflowID else { return }
        totalDuration = result.timings.total
        phase = result.degradations.isEmpty ? .succeeded : .degraded
    }

    /// The surface owns microphone acquisition. Mark the source as genuinely
    /// running while capture is in progress; the engine later validates and
    /// consumes the frozen audio envelope using the same run identity.
    mutating func beginSourceCapture() {
        guard !nodes.isEmpty, nodes[0].role == .source else { return }
        phase = .running
        nodes[0].state = .running
    }

    private mutating func update(step: VoiceWorkflowStep, state: NodeState) {
        guard let index = nodes.firstIndex(where: {
            $0.index == step.index && $0.widgetID == step.widgetID
        }) else { return }
        nodes[index].state = state
    }
}

private extension WorkflowRunPresentation.Phase {
    var isTerminal: Bool {
        switch self {
        case .idle, .running: false
        case .succeeded, .degraded, .failed, .cancelled: true
        }
    }
}

// MARK: - RecordGestureAction

/// What a press-and-hold gesture change should do to the recorder.
enum RecordGestureAction: Equatable {
    case start
    case stop
    case none
}

// MARK: - DictationViewModel

/// Orchestrates STT transcription and optional LLM post-processing.
/// Also drives the recording UI state for DictationView.
final class DictationViewModel: ObservableObject, @unchecked Sendable {

    // MARK: - UI State

    enum RecordingState: Equatable {
        case idle
        case starting
        case recording
        case processing
        case result(transcript: String, processed: String?)
        case error(message: String)
    }

    @Published var recordingState: RecordingState = .idle
    @Published var audioLevel: Float = 0
    @Published var sttLatency: TimeInterval = 0
    @Published var llmLatency: TimeInterval = 0
    @Published private(set) var workflowPresentation: WorkflowRunPresentation = .idle

    private var frozenSTTProviderName: String?
    private var frozenLLMProviderName: String?
    private var preparedMainWorkflow: PreparedMainWorkflow?
    private var activeCaptureStartID: UUID?

    private var effectiveActiveWorkflowID: String {
        let catalog = config.workflowCatalog
        let legacyCandidate = WorkflowMigration.workflowID(
            forLegacyModeID: config.activeModeID
        )
        guard !config.activeVoiceWorkflowID.isEmpty else {
            return catalog.workflow(id: legacyCandidate) == nil
                ? "wf.dictation"
                : legacyCandidate
        }
        return config.activeVoiceWorkflowID
    }

    /// Recipe selected for the main Dictate surface. Legacy mode state is
    /// migrated to this id by `WorkflowMigration`; execution and UI both read
    /// this same definition.
    var activeWorkflowDefinition: WorkflowDefinition? {
        config.workflowCatalog.workflow(id: effectiveActiveWorkflowID)
    }

    var workflowDisplayNodes: [WorkflowRunPresentation.Node] {
        if !workflowPresentation.nodes.isEmpty {
            return workflowPresentation.nodes
        }
        guard let definition = activeWorkflowDefinition else { return [] }
        let surface = mainSurfaceWorkflow(
            definition: definition,
            catalog: config.workflowCatalog
        )
        return WorkflowRunPresentation.preview(
            definition: surface.definition,
            catalog: surface.catalog
        ).nodes
    }

    var activeVocabularyTermCount: Int {
        let scopeID = activeWorkflowDefinition.flatMap { legacyScopeID(for: $0) }
            ?? effectiveActiveWorkflowID
        var books = vocabStore.effectiveBooks(modeID: scopeID)
        if let definition = activeWorkflowDefinition {
            for widgetID in definition.processors {
                guard let widget = config.workflowCatalog.widget(id: widgetID) else { continue }
                for id in widget.props["vocab_books"]?.stringArray ?? [] {
                    guard !books.contains(where: { $0.id == id }),
                          let book = vocabStore.book(id: id) else { continue }
                    books.append(book)
                }
            }
        }
        return VocabApplier.collectTerms(books).count
    }

    var activeWorkflowUsesLLM: Bool {
        guard let definition = activeWorkflowDefinition else { return false }
        let catalog = config.workflowCatalog
        return definition.processors.contains { id in
            catalog.widget(id: id)?.typeTag == "llm"
        }
    }

    /// Capture gesture comes from the recipe source after migration. Desktop
    /// `hold` maps to press-and-hold; `toggle` maps to the iOS tap surface.
    var activeRecordMode: RecordMode {
        guard let definition = activeWorkflowDefinition,
              let source = config.workflowCatalog.widget(id: definition.source) else {
            return config.recordMode
        }
        return source.props["capture"]?.stringValue == "toggle" ? .tap : .hold
    }

    private func legacyScopeID(for definition: WorkflowDefinition) -> String? {
        return WorkflowMigration.legacyModeID(forWorkflowID: definition.id)
    }

    /// Current mode — derived from config.activeModeID
    var currentMode: Mode {
        let legacyModeID = activeWorkflowDefinition.flatMap { legacyScopeID(for: $0) }
            ?? config.activeModeID
        if legacyModeID == "translate" {
            return .translate(targetLanguage: config.translateTargetLanguage)
        }
        return config.modeConfigs.first(where: { $0.id == legacyModeID })?.mode ?? .raw
    }

    /// Selects a concrete ModeConfig identity. This is required for custom
    /// modes, whose `Mode.id` intentionally collapses to "custom".
    @MainActor
    func selectMode(id: String) {
        WorkflowMigration.migrate(&config)
        let workflowID: String
        if config.workflowCatalog.workflow(id: id) != nil {
            workflowID = id
        } else {
            workflowID = WorkflowMigration.workflowID(forLegacyModeID: id)
        }
        guard let definition = config.workflowCatalog.workflow(id: workflowID),
              (try? VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: config.workflowCatalog,
                config: config
              )) != nil else { return }
        guard !isCaptureActive else { return }
        if case .processing = recordingState { return }
        config.activeVoiceWorkflowID = workflowID
        if let legacyModeID = WorkflowMigration.legacyModeID(forWorkflowID: workflowID) {
            config.activeModeID = legacyModeID
        }
        switch recordingState {
        case .result, .error:
            recordingState = .idle
        case .idle, .starting, .recording, .processing:
            break
        }
        resetFlowUI()
    }

    /// Convenience for views/tests: true when actively recording.
    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    private var isCaptureActive: Bool {
        switch recordingState {
        case .starting, .recording: true
        case .idle, .processing, .result, .error: false
        }
    }

    // MARK: - Services

    private let audioCapture: any AudioCapturing
    private var levelPollTimer: Timer?
    private var processingTask: Task<Void, Never>?
    private var activeProcessingID: UUID?

    /// SwiftData context for persisting completed sessions to History.
    /// Set by ContentView; nil in unit tests that don't exercise persistence.
    var modelContext: ModelContext?

    /// Vocab books + mounts (P1-1). Feeds STT biasing, deterministic
    /// corrections, and LLM glossaries in processAudio.
    var vocabStore = VocabStore()

    /// AppConfig reference — read by resolveSTT/LLM to pick the right provider.
    /// Updated from ContentView when settings change.
    @Published var config: AppConfig = WorkflowMigration.migrated(AppConfig())

    // MARK: - Init

    init() {
        audioCapture = AudioCaptureService()
    }

    /// Test initialiser with explicit providers.
    private var _testSTT: (any STTProvider)?
    private var _testLLM: (any LegacyModeLLMProvider)?
    init(sttProvider: (any STTProvider)?,
         llmService: (any LegacyModeLLMProvider)? = nil,
         audioCapture: any AudioCapturing = AudioCaptureService()) {
        self._testSTT = sttProvider
        self._testLLM = llmService
        self.audioCapture = audioCapture
    }

    // MARK: - Provider Resolution

    /// Resolve the current STT provider from config. Falls back to Apple Speech.
    var sttProvider: any STTProvider {
        resolvedSTTProvider(scopeID: config.activeModeID)
    }

    /// Human-readable name of the current STT provider for UI display.
    var sttProviderName: String {
        if let frozenSTTProviderName { return frozenSTTProviderName }
        let profileID = activeProcessorProfileID(
            typeTag: "stt",
            fallback: fallbackProfileID(for: "stt")
        )
        guard let profile = config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasSTT
        }) else { return "Apple Speech" }
        return profile.name
    }

    /// Human-readable name of the current LLM provider for UI display.
    var llmProviderName: String? {
        if let frozenLLMProviderName { return frozenLLMProviderName }
        guard activeWorkflowUsesLLM else { return nil }
        let profileID = activeProcessorProfileID(
            typeTag: "llm",
            fallback: fallbackProfileID(for: "llm")
        )
        return config.modelProfiles.first(where: {
            $0.id == profileID && $0.hasLLM
        })?.name
    }

    private func activeProcessorProfileID(typeTag: String, fallback: String) -> String {
        guard let definition = activeWorkflowDefinition else { return fallback }
        let catalog = config.workflowCatalog
        guard let widget = definition.processors
            .compactMap({ catalog.widget(id: $0) })
            .first(where: { $0.typeTag == typeTag }) else { return fallback }
        let explicit = widget.props["model_profile"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explicit.isEmpty ? fallback : explicit
    }

    private func fallbackProfileID(for typeTag: String) -> String {
        let scopeID = activeWorkflowDefinition.flatMap { legacyScopeID(for: $0) }
        switch typeTag {
        case "stt":
            return scopeID.map { config.effectiveSTTProfileID(forModeID: $0) }
                ?? config.sttProfile
        case "llm":
            return scopeID.map { config.effectiveLLMProfileID(forModeID: $0) }
                ?? config.llmProfile
        default:
            return ""
        }
    }

    private func resolvedSTTProvider(scopeID: String?) -> any STTProvider {
        if let test = _testSTT { return test }
        let profileID = config.effectiveSTTProfileID(forModeID: scopeID)
        return STTResolver.resolve(config: config, profileID: profileID)
    }

    private struct MainSurfaceWorkflow {
        let definition: WorkflowDefinition
        let catalog: WorkflowCatalog
        let destinationsByWidgetID: [String: AnyTextDestination]
        let destinationSummary: String
    }

    private struct PreparedMainWorkflow {
        let runID: UUID
        let sourceStartedAt: Date
        /// Persisted/shared identity, before ephemeral iOS output adapters.
        let persistedDefinition: WorkflowDefinition
        let surface: MainSurfaceWorkflow
        let compiled: VoiceWorkflowPlanFactory.Compilation
    }

    /// Resolve every mutable setting before execution. The engine receives
    /// only frozen providers, vocab snapshots and output adapters.
    @MainActor
    private func compileMainWorkflow(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        legacyScopeID: String?,
        legacyMode: Mode,
        destinationsByWidgetID: [String: AnyTextDestination]
    ) throws -> VoiceWorkflowPlanFactory.Compilation {
        let llmOverride: (any VoiceWorkflowLLMProvider)?
        if let test = _testLLM {
            llmOverride = LegacyVoiceWorkflowLLMAdapter(
                provider: test,
                mode: legacyMode,
                glossary: testProviderGlossary(
                    definition: definition,
                    catalog: catalog,
                    legacyScopeID: legacyScopeID
                )
            )
        } else {
            llmOverride = nil
        }
        let frozenDestinations = destinationsByWidgetID
        let compiled = try VoiceWorkflowPlanFactory(
            config: config,
            vocabStore: vocabStore,
            sttProviderOverride: _testSTT,
            llmProviderOverride: llmOverride,
            llmOverrideName: llmOverride == nil ? nil : "Test LLM"
        ).compile(
            definition: definition,
            catalog: catalog,
            legacyScopeID: legacyScopeID,
            supportedOutputTypes: [
                "insert", "return_to_caller", "clipboard", "ios_destination"
            ],
            allowSurfaceOutputs: true,
            resolveOutput: { widget in
                switch widget.typeTag {
                case "insert", "return_to_caller":
                    return ReturnToCallerVoiceWorkflowOutput()
                case "clipboard":
                    return TextDestinationVoiceWorkflowOutput(
                        destination: AnyTextDestination(ClipboardDestination())
                    )
                case "ios_destination":
                    guard let destination = frozenDestinations[widget.id] else {
                        throw VoiceWorkflowCompileError.resolutionFailed(
                            widgetID: widget.id,
                            reason: "iOS destination was not frozen"
                        )
                    }
                    return TextDestinationVoiceWorkflowOutput(destination: destination)
                default:
                    throw VoiceWorkflowCompileError.unsupportedWidget(
                        widgetID: widget.id,
                        role: widget.role,
                        typeTag: widget.typeTag
                    )
                }
            }
        )
        frozenSTTProviderName = compiled.sttProviderName
        frozenLLMProviderName = compiled.llmProviderName
        return compiled
    }

    private func testProviderGlossary(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        legacyScopeID: String?
    ) -> String? {
        var books = vocabStore.effectiveBooks(
            modeID: legacyScopeID ?? definition.id
        )
        for processorID in definition.processors {
            guard let widget = catalog.widget(id: processorID) else { continue }
            for id in widget.props["vocab_books"]?.stringArray ?? [] {
                guard !books.contains(where: { $0.id == id }),
                      let book = vocabStore.book(id: id),
                      book.enabled else { continue }
                books.append(book)
            }
        }
        return VoiceWorkflowVocabulary(effectiveBooks: books).glossary
    }

    /// Build the effective mobile topology. Legacy auto-send is represented as
    /// an ephemeral output widget so it participates in validation, trace,
    /// cancellation and failure semantics without leaking an iOS-only widget
    /// into the shared desktop scenario format.
    private func mainSurfaceWorkflow(
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog
    ) -> MainSurfaceWorkflow {
        var effectiveDefinition = definition
        var effectiveCatalog = catalog
        var destinationsByWidgetID: [String: AnyTextDestination] = [:]

        var deliveredIDs: [String] = []
        for outputID in definition.outputs {
            guard let widget = catalog.widget(id: outputID) else { continue }
            let destinationID: String
            switch widget.typeTag {
            case "clipboard": destinationID = "clipboard"
            case "insert", "return_to_caller": destinationID = "result"
            case "ios_destination":
                destinationID = widget.props["destination_id"]?.stringValue ?? widget.id
            default: destinationID = widget.id
            }
            if !deliveredIDs.contains(destinationID) { deliveredIDs.append(destinationID) }
        }

        if !config.autoSendDestination.isEmpty,
           !deliveredIDs.contains(config.autoSendDestination),
           let destination = config.destinations.first(where: {
               $0.id == config.autoSendDestination
           }) {
            let widgetID = "out.ios-auto"
            let widget = WorkflowWidget(
                id: widgetID,
                role: .output,
                typeTag: "ios_destination",
                name: "Auto-send · \(destinationDisplayName(destination.id))",
                icon: "arrow.up.forward.app",
                props: .object(["destination_id": .string(destination.id)])
            )
            if let index = effectiveCatalog.widgets.firstIndex(where: { $0.id == widgetID }) {
                effectiveCatalog.widgets[index] = widget
            } else {
                effectiveCatalog.widgets.append(widget)
            }
            effectiveDefinition.outputs.append(widgetID)
            destinationsByWidgetID[widgetID] = destination
            deliveredIDs.append(destination.id)
        }

        return MainSurfaceWorkflow(
            definition: effectiveDefinition,
            catalog: effectiveCatalog,
            destinationsByWidgetID: destinationsByWidgetID,
            destinationSummary: deliveredIDs.joined(separator: ",")
        )
    }

    private func destinationDisplayName(_ id: String) -> String {
        switch id {
        case "clipboard": return String(localized: "Clipboard")
        case "messages": return String(localized: "Messages")
        case "url_scheme": return String(localized: "URL Scheme")
        case "result": return String(localized: "Result")
        default: return id
        }
    }

    @MainActor
    private func prepareMainWorkflow() throws -> PreparedMainWorkflow {
        WorkflowMigration.migrate(&config)
        let catalog = config.workflowCatalog
        guard let definition = catalog.workflow(id: config.activeVoiceWorkflowID) else {
            throw VoiceWorkflowCompileError.unknownWidget(
                workflowID: config.activeVoiceWorkflowID,
                widgetID: config.activeVoiceWorkflowID
            )
        }
        guard catalog.widget(id: definition.source)?.typeTag == "microphone" else {
            throw VoiceWorkflowCompileError.unsupportedWidget(
                widgetID: definition.source,
                role: .source,
                typeTag: catalog.widget(id: definition.source)?.typeTag ?? "missing"
            )
        }

        let legacyScopeID = legacyScopeID(for: definition)
        let mode = currentMode
        let surface = mainSurfaceWorkflow(definition: definition, catalog: catalog)
        let compiled = try compileMainWorkflow(
            definition: surface.definition,
            catalog: surface.catalog,
            legacyScopeID: legacyScopeID,
            legacyMode: mode,
            destinationsByWidgetID: surface.destinationsByWidgetID
        )
        return PreparedMainWorkflow(
            runID: UUID(),
            sourceStartedAt: Date(),
            persistedDefinition: definition,
            surface: surface,
            compiled: compiled
        )
    }

    /// Poll audio level at 10fps — fast enough for waveform, slow enough to not starve touch events.
    private func startLevelPolling() {
        levelPollTimer?.invalidate()
        levelPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level = self.audioCapture.currentAudioLevel
            // Only update if level actually changed (avoids unnecessary SwiftUI re-renders)
            if abs(self.audioLevel - level) > 0.01 {
                self.audioLevel = level
            }
        }
    }

    private func stopLevelPolling() {
        levelPollTimer?.invalidate()
        levelPollTimer = nil
        audioLevel = 0
    }

    // MARK: - Hold-to-record gesture logic

    /// Decides how a hold-gesture change maps onto recorder actions.
    /// Inert unless the configured record mode is `.hold`.
    static func holdGestureAction(pressing: Bool,
                                  state: RecordingState,
                                  recordMode: RecordMode) -> RecordGestureAction {
        guard recordMode == .hold else { return .none }
        switch (pressing, state) {
        case (true, .idle), (true, .result), (true, .error):
            return .start
        case (false, .starting), (false, .recording):
            return .stop
        default:
            return .none
        }
    }

    // MARK: - Recording Control

    @MainActor
    func startRecording() {
        log.info("▶️ startRecording() called, isRecording=\(self.isRecording)")
        guard !isCaptureActive else {
            log.warning("⚠️ Capture is already starting or recording, ignoring start")
            return
        }

        cancelInFlightProcessing()
        resetFlowUI()

        let permission = audioCapture.micPermissionStatus()
        log.info("🎤 Mic permission status: \(String(describing: permission.rawValue))")

        switch permission {
        case .granted:
            log.info("✅ Permission granted, calling doStartCapture()")
            doStartCapture()
        case .undetermined:
            log.info("❓ Permission undetermined, requesting...")
            Task { @MainActor in
                let granted = await audioCapture.requestMicPermission()
                log.info("🎤 Permission request result: \(granted)")
                if granted {
                    doStartCapture()
                } else {
                    recordingState = .error(message: "Microphone permission is required. Please enable it in Settings.")
                }
            }
        case .denied:
            log.error("❌ Permission denied")
            recordingState = .error(message: "Microphone permission denied. Go to Settings → Privacy → Microphone to enable.")
        @unknown default:
            log.error("❌ Permission unknown")
            recordingState = .error(message: "Microphone permission unavailable.")
        }
    }

    @MainActor
    private func doStartCapture() {
        log.info("🔴 doStartCapture() — starting engine on background thread")

        // More than one permission-waiting task can resume together (for
        // example after duplicate deep links). Only the first may own capture.
        guard !isCaptureActive else {
            log.warning("⚠️ Capture became active while awaiting permission")
            return
        }

        cancelInFlightProcessing()
        resetFlowUI()

        let prepared: PreparedMainWorkflow
        do {
            prepared = try prepareMainWorkflow()
        } catch {
            log.error("❌ Recipe preflight failed: \(error.localizedDescription)")
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
        let captureStartID = UUID()
        activeCaptureStartID = captureStartID
        recordingState = .starting

        // Start audio engine on background thread to avoid blocking main thread
        audioCapture.startCapture(
            onInterruption: { [weak self] in
                DispatchQueue.main.async {
                    self?.handleCaptureInterruption()
                }
            },
            completion: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self,
                          self.activeCaptureStartID == captureStartID else { return }
                    self.activeCaptureStartID = nil
                    if let error {
                        log.error("❌ Engine start failed: \(error.localizedDescription)")
                        self.preparedMainWorkflow = nil
                        self.recordingState = .error(message: error.localizedDescription)
                        self.stopLevelPolling()
                    } else {
                        log.info("✅ Engine started successfully on background thread")
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
        log.info("⏹ stopRecording() called")
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
            log.info("⏹ Got WAV data: \(wavData?.count ?? 0) bytes")
            finishRecording(wavData: wavData ?? Data())

        case .idle, .processing, .result, .error:
            return
        }
    }

    @MainActor
    private func handleCaptureInterruption() {
        guard isCaptureActive else { return }
        activeCaptureStartID = nil
        preparedMainWorkflow = nil
        stopLevelPolling()
        resetFlowUI()
        recordingState = .error(
            message: "Recording was interrupted. Please try again."
        )
    }

    /// Executes the source → processors → outputs plan frozen at capture start.
    /// Tests and non-capture callers get the same preflight as a fallback.
    @MainActor
    func finishRecording(wavData: Data) {
        processingTask?.cancel()
        let prepared: PreparedMainWorkflow
        do {
            prepared = try preparedMainWorkflow ?? prepareMainWorkflow()
        } catch {
            log.error("❌ Recipe preflight failed: \(error.localizedDescription)")
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
                log.info("🔄 Running voice recipe \(prepared.persistedDefinition.id, privacy: .public)...")
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
                let result = processResult(
                    from: workflowResult
                )
                log.info("✅ Processing complete: \(result.text.prefix(50))...")
                workflowPresentation.complete(with: workflowResult)
                recordingState = .result(
                    transcript: result.rawTranscript,
                    processed: result.text == result.rawTranscript ? nil : result.text
                )

            } catch is CancellationError {
                log.info("⏹ Processing cancelled")
            } catch {
                guard activeProcessingID == processingID else { return }
                log.error("❌ Processing failed: \(error.localizedDescription)")
                recordingState = .error(message: error.localizedDescription)
            }
        }
    }

    @MainActor
    private func cancelInFlightProcessing() {
        activeProcessingID = nil
        processingTask?.cancel()
        processingTask = nil
        preparedMainWorkflow = nil
    }

    @MainActor
    private func resetFlowUI() {
        workflowPresentation = .idle
        frozenSTTProviderName = nil
        frozenLLMProviderName = nil
        sttLatency = 0
        llmLatency = 0
    }

    @MainActor
    private func receiveWorkflowEvent(_ event: VoiceWorkflowTraceEvent) {
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
    private func processResult(from result: VoiceWorkflowResult) -> ProcessResult {
        let sttDuration = result.timings.steps
            .filter { $0.step.typeTag == "stt" }
            .reduce(0) { $0 + $1.duration }
        let llmSteps = result.timings.steps.filter { $0.step.typeTag == "llm" }
        let llmDuration = llmSteps.isEmpty
            ? nil
            : llmSteps.reduce(0) { $0 + $1.duration }
        let llmSucceeded = result.trace.contains { event in
            guard case .stepFinished(_, _, let step, let outcome, _) = event else {
                return false
            }
            return step.typeTag == "llm" && outcome == .succeeded
        }

        sttLatency = sttDuration
        llmLatency = llmDuration ?? 0
        return ProcessResult(
            text: result.finalText,
            rawTranscript: result.rawText,
            isRawFallback: !result.degradations.isEmpty,
            providerTranscript: result.providerTranscript,
            didProcessWithLLM: llmSucceeded,
            degradations: result.degradations,
            timings: result.timings
        )
    }

    /// Engine recorder hook: persists after processors but before outputs, so
    /// a failed delivery still leaves recoverable text in History.
    @MainActor
    private func persistSession(
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
            log.error("❌ Failed to persist workflow record: \(error.localizedDescription)")
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

    // MARK: - Core Pipeline (also used by tests directly)

    /// Transcribe audio data using the configured STT provider.
    /// - Throws: `DictationError.noSTTProviderConfigured` if no provider is set.
    func transcribeAudio(_ audioData: Data, language: String?) async throws -> String {
        return try await sttProvider.transcribe(audioData: audioData, language: language)
    }

    /// Transcribe audio and optionally apply LLM post-processing.
    /// If LLM processing fails, falls back to the corrected transcript.
    func processAudio(_ audioData: Data,
                      language: String?,
                      mode: Mode,
                      scopeID: String? = nil) async throws -> ProcessResult {
        try Task.checkCancellation()
        let plan = try await MainActor.run {
            try canonicalProcessAudioPlan(
                language: language,
                mode: mode,
                scopeID: scopeID
            )
        }
        await MainActor.run {
            sttLatency = 0
            llmLatency = 0
        }
        let workflowResult = try await VoiceWorkflowEngine().run(
            VoiceWorkflowRunInput(
                audioData: audioData,
                source: plan.validation.sourceKind
            ),
            using: plan
        )
        try Task.checkCancellation()
        return await MainActor.run {
            processResult(from: workflowResult)
        }
    }

    /// Test/compatibility entry point preparation. It uses the same migrated
    /// definition, operational validation, provider factory and frozen plan as
    /// production Dictate; only output delivery is intercepted.
    @MainActor
    private func canonicalProcessAudioPlan(
        language: String?,
        mode: Mode,
        scopeID: String?
    ) throws -> ResolvedVoiceWorkflow {
        let resolvedScopeID = scopeID ?? mode.id
        let configSnapshot = canonicalConfigSnapshot(
            resolvedScopeID: resolvedScopeID,
            mode: mode
        )

        let workflowID = WorkflowMigration.workflowID(
            forLegacyModeID: resolvedScopeID
        )
        var catalog = configSnapshot.workflowCatalog
        guard let definition = catalog.workflow(id: workflowID) else {
            throw VoiceWorkflowCompileError.unknownWidget(
                workflowID: workflowID,
                widgetID: workflowID
            )
        }

        let modeConfig = configSnapshot.modeConfigs.first {
            $0.id == resolvedScopeID
        }
        for processorID in definition.processors {
            guard let index = catalog.widgets.firstIndex(where: {
                $0.id == processorID
            }), case .object(var props) = catalog.widgets[index].props else {
                continue
            }
            switch catalog.widgets[index].typeTag {
            case "stt":
                props["language"] = .string(language ?? configSnapshot.sttLanguage)
                if let modeConfig {
                    props["stt_prompt"] = .string(modeConfig.sttPrompt)
                    props["temperature"] = .number(modeConfig.sttTemperature)
                    if let profileID = modeConfig.sttModelID {
                        props["model_profile"] = .string(profileID)
                    }
                }
                catalog.widgets[index].props = .object(props)

            case "llm":
                let canonical = WorkflowCanonicalLLM.definition(for: mode)
                props["system"] = .string(canonical.system)
                props["user_template"] = .string(canonical.userTemplate)
                props["temperature"] = .number(canonical.temperature)
                props["max_tokens"] = .integer(canonical.maxTokens)
                if let modeConfig {
                    props["output_language"] = .string(modeConfig.outputLanguage)
                    if let profileID = modeConfig.llmModelID {
                        props["model_profile"] = .string(profileID)
                    }
                }
                catalog.widgets[index].props = .object(props)

            default:
                break
            }
        }

        let llmOverride = canonicalLLMOverride(
            mode: mode,
            definition: definition,
            catalog: catalog,
            resolvedScopeID: resolvedScopeID
        )
        return try VoiceWorkflowPlanFactory(
            config: configSnapshot,
            vocabStore: vocabStore,
            sttProviderOverride: _testSTT,
            llmProviderOverride: llmOverride,
            llmOverrideName: llmOverride == nil ? nil : "Test LLM"
        ).compile(
            definition: definition,
            catalog: catalog,
            legacyScopeID: resolvedScopeID,
            resolveOutput: { _ in ReturnToCallerVoiceWorkflowOutput() }
        ).plan
    }

    @MainActor
    private func canonicalConfigSnapshot(
        resolvedScopeID: String,
        mode: Mode
    ) -> AppConfig {
        var configSnapshot = config
        if !configSnapshot.modeConfigs.contains(where: { $0.id == resolvedScopeID }) {
            configSnapshot.modeConfigs.append(ModeConfig(
                id: resolvedScopeID,
                mode: mode,
                name: resolvedScopeID,
                icon: mode.icon,
                description: "",
                sttModelID: nil,
                llmModelID: nil,
                sttPrompt: "",
                sttTemperature: 0,
                outputLanguage: "auto",
                autoPaste: false,
                isBuiltIn: false
            ))
        }
        WorkflowMigration.migrate(&configSnapshot)
        return configSnapshot
    }

    @MainActor
    private func canonicalLLMOverride(
        mode: Mode,
        definition: WorkflowDefinition,
        catalog: WorkflowCatalog,
        resolvedScopeID: String
    ) -> (any VoiceWorkflowLLMProvider)? {
        guard let test = _testLLM else { return nil }
        return LegacyVoiceWorkflowLLMAdapter(
            provider: test,
            mode: mode,
            glossary: testProviderGlossary(
                definition: definition,
                catalog: catalog,
                legacyScopeID: resolvedScopeID
            )
        )
    }
}
