import Foundation
import SwiftUI
import SwiftData
import os.log

let dictationLog = Logger(subsystem: "com.fonos.ios", category: "DictationViewModel")

struct TextDestinationVoiceWorkflowOutput: VoiceWorkflowOutput {
    let destination: AnyTextDestination

    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {
        try await destination.send(text: text)
    }
}

/// Destinations accepted by the public `fonos://record?destination=…`
/// contract. They are resolved separately from AppConfig because a Shortcut
/// route applies to exactly one run and must never become a persisted setting.
enum DictationOneShotDestination: String, CaseIterable, Equatable, Sendable {
    case clipboard
    case messages
    case email
    case share

    static func resolve(_ value: String) throws -> Self {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "clipboard", "copy": .clipboard
        case "messages", "message", "sms": .messages
        case "email", "mail": .email
        case "share", "share_sheet", "sharesheet": .share
        default:
            throw DictationOneShotDestinationError.unsupported(value)
        }
    }

    var displayName: String {
        switch self {
        case .clipboard: String(localized: "Clipboard")
        case .messages: String(localized: "Messages")
        case .email: String(localized: "Email")
        case .share: String(localized: "Share")
        }
    }

    var icon: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .messages: "message.fill"
        case .email: "envelope.fill"
        case .share: "square.and.arrow.up"
        }
    }
}

enum DictationOneShotDestinationError: LocalizedError, Equatable {
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let value):
            "Unsupported dictation destination ‘\(value)’. Use clipboard, messages, email, or share."
        }
    }
}

struct OneShotDictationVoiceWorkflowOutput: VoiceWorkflowOutput {
    let destination: DictationOneShotDestination

    func deliver(text: String, context: VoiceWorkflowOutputContext) async throws {
        switch destination {
        case .clipboard:
            await MainActor.run {
                UIPasteboard.general.string = text
            }

        case .messages:
            let url = try MessagesDestination().buildURL(for: text)
            guard await requestSystemOpen(url) else {
                throw DestinationError.destinationUnavailable(destination.rawValue)
            }

        case .email:
            var components = URLComponents()
            components.scheme = "mailto"
            components.queryItems = [URLQueryItem(name: "body", value: text)]
            guard let url = components.url,
                  await requestSystemOpen(url) else {
                throw DestinationError.destinationUnavailable(destination.rawValue)
            }

        case .share:
            let didPresent = await MainActor.run {
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                      let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
                        ?? scene.windows.first?.rootViewController else {
                    return false
                }
                var presenter = root
                while let presented = presenter.presentedViewController {
                    presenter = presented
                }
                let controller = UIActivityViewController(
                    activityItems: [text],
                    applicationActivities: nil
                )
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                }
                presenter.present(controller, animated: true)
                return true
            }
            guard didPresent else {
                throw DestinationError.destinationUnavailable(destination.rawValue)
            }
        }
    }

    /// Keep UIApplication wholly on the main actor. The completion result is
    /// not needed by the workflow; `canOpenURL` provides the synchronous
    /// availability contract while `open` hands the route to iOS.
    private func requestSystemOpen(_ url: URL) async -> Bool {
        await MainActor.run {
            guard UIApplication.shared.canOpenURL(url) else { return false }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }
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
    @Published var workflowPresentation: WorkflowRunPresentation = .idle

    var frozenSTTProviderName: String?
    var frozenLLMProviderName: String?
    var preparedMainWorkflow: PreparedMainWorkflow?
    var activeCaptureStartID: UUID?
    var pendingOneShotDestination: DictationOneShotDestination?

    /// Exposed internally for contract tests and diagnostics. This value is
    /// consumed when the next workflow snapshot is prepared; it is not part of
    /// AppConfig and therefore cannot leak into later recordings.
    var pendingOneShotDestinationID: String? {
        pendingOneShotDestination?.rawValue
    }

    var effectiveActiveWorkflowID: String {
        config.activeVoiceWorkflowID.isEmpty
            ? "wf.dictation"
            : config.activeVoiceWorkflowID
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

    func legacyScopeID(for definition: WorkflowDefinition) -> String? {
        return WorkflowMigration.legacyModeID(forWorkflowID: definition.id)
    }

    /// Selects a concrete workflow identity. A legacy mode id is accepted only
    /// as an input compatibility alias and is immediately mapped to its recipe.
    @MainActor
    @discardableResult
    func selectMode(id: String) -> Bool {
        WorkflowMigration.migrate(&config)
        let workflowID: String
        if config.workflowCatalog.workflow(id: id) != nil {
            workflowID = id
        } else {
            workflowID = WorkflowMigration.workflowID(forLegacyModeID: id)
        }
        guard config.isVoiceWorkflowEnabled(workflowID),
              let definition = config.workflowCatalog.workflow(id: workflowID),
              (try? VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: definition,
                catalog: config.workflowCatalog,
                config: config
              )) != nil else { return false }
        guard !isCaptureActive else { return false }
        if case .processing = recordingState { return false }
        config.activeVoiceWorkflowID = workflowID
        switch recordingState {
        case .result, .error:
            recordingState = .idle
        case .idle, .starting, .recording, .processing:
            break
        }
        resetFlowUI()
        return true
    }

    /// Applies a typed deep-link request and starts capture. Destination is a
    /// one-shot execution override; mode remains the existing public selection
    /// contract. Invalid values are surfaced in the Dictate UI instead of
    /// silently recording with a different route.
    @MainActor
    @discardableResult
    func startRecording(from request: DictationDeepLinkRequest) -> Bool {
        guard !isRunBusy else {
            dictationLog.warning("⚠️ Ignored deep-link start while another dictation run is active")
            return false
        }

        if let modeID = request.modeID, !selectMode(id: modeID) {
            pendingOneShotDestination = nil
            recordingState = .error(
                message: "The requested dictation workflow ‘\(modeID)’ is unavailable."
            )
            return false
        }

        do {
            pendingOneShotDestination = try request.destinationID.map {
                try DictationOneShotDestination.resolve($0)
            }
        } catch {
            pendingOneShotDestination = nil
            recordingState = .error(message: error.localizedDescription)
            return false
        }

        startRecording()
        return true
    }

    /// Convenience for views/tests: true when actively recording.
    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    var isCaptureActive: Bool {
        switch recordingState {
        case .starting, .recording: true
        case .idle, .processing, .result, .error: false
        }
    }

    var isRunBusy: Bool {
        switch recordingState {
        case .starting, .recording, .processing: true
        case .idle, .result, .error: false
        }
    }

    // MARK: - Services

    let audioCapture: any AudioCapturing
    var levelPollTimer: Timer?
    var processingTask: Task<Void, Never>?
    var activeProcessingID: UUID?

    /// SwiftData context for persisting completed sessions to History.
    /// Set by ContentView; nil in unit tests that don't exercise persistence.
    var modelContext: ModelContext?

    /// Vocab books + mounts (P1-1). Feeds STT biasing, deterministic
    /// corrections, and LLM glossaries in the compiled workflow.
    var vocabStore = VocabStore()

    /// AppConfig reference — read by resolveSTT/LLM to pick the right provider.
    /// Updated from ContentView when settings change.
    @Published var config: AppConfig = WorkflowMigration.migrated(AppConfig())

    // MARK: - Init

    init() {
        audioCapture = AudioCaptureService()
    }

    /// Test initialiser with explicit providers.
    var _testSTT: (any STTProvider)?
    var _testLLM: (any VoiceWorkflowLLMProvider)?
    init(sttProvider: (any STTProvider)?,
         llmProvider: (any VoiceWorkflowLLMProvider)? = nil,
         audioCapture: any AudioCapturing = AudioCaptureService()) {
        self._testSTT = sttProvider
        self._testLLM = llmProvider
        self.audioCapture = audioCapture
    }

    // MARK: - Provider Resolution

    /// Human-readable name of the current STT provider for UI display.
}
