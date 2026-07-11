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
    /// Semantic LLM result used by the Flow UI.
    let llmOutcome: SpeechFlowLLMOutcome
    let degradation: SpeechFlowDegradation?
    let timings: SpeechFlowTimings

    init(text: String,
         rawTranscript: String? = nil,
         isRawFallback: Bool = false,
         providerTranscript: String? = nil,
         didProcessWithLLM: Bool = false,
         llmOutcome: SpeechFlowLLMOutcome? = nil,
         degradation: SpeechFlowDegradation? = nil,
         timings: SpeechFlowTimings = .zero) {
        self.text = text
        self.rawTranscript = rawTranscript ?? text
        self.providerTranscript = providerTranscript ?? rawTranscript ?? text
        self.isRawFallback = isRawFallback
        self.didProcessWithLLM = didProcessWithLLM
        self.llmOutcome = llmOutcome
            ?? (didProcessWithLLM ? .succeeded : (isRawFallback ? .fellBackToInput : .skipped(.notRequested)))
        self.degradation = degradation
        self.timings = timings
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
        case recording
        case processing
        case result(transcript: String, processed: String?)
        case error(message: String)
    }

    @Published var recordingState: RecordingState = .idle
    @Published var audioLevel: Float = 0
    @Published var sttLatency: TimeInterval = 0
    @Published var llmLatency: TimeInterval = 0
    @Published private(set) var flowPresentation: SpeechFlowPresentation = .idle

    private var frozenSTTProviderName: String?
    private var frozenLLMProviderName: String?

    /// Current mode — derived from config.activeModeID
    var currentMode: Mode {
        if config.activeModeID == "translate" {
            return .translate(targetLanguage: config.translateTargetLanguage)
        }
        return config.activeModeConfig?.mode ?? .raw
    }

    /// Selects a concrete ModeConfig identity. This is required for custom
    /// modes, whose `Mode.id` intentionally collapses to "custom".
    @MainActor
    func selectMode(id: String) {
        guard config.modeConfigs.contains(where: { $0.id == id }) else { return }
        guard !isRecording else { return }
        if case .processing = recordingState { return }
        config.activeModeID = id
        switch recordingState {
        case .result, .error:
            recordingState = .idle
        case .idle, .recording, .processing:
            break
        }
        resetFlowUI()
    }

    /// Convenience for views/tests: true when actively recording.
    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    // MARK: - Services

    private let audioCapture: AudioCaptureService
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
    @Published var config: AppConfig = AppConfig()

    // MARK: - Init

    init() {
        audioCapture = AudioCaptureService()
    }

    /// Test initialiser with explicit providers.
    private var _testSTT: (any STTProvider)?
    private var _testLLM: (any SpeechFlowLLMProvider)?
    init(sttProvider: (any STTProvider)?,
         llmService: (any SpeechFlowLLMProvider)? = nil,
         audioCapture: AudioCaptureService = AudioCaptureService()) {
        self._testSTT = sttProvider
        self._testLLM = llmService
        self.audioCapture = audioCapture
    }

    // MARK: - Provider Resolution

    /// Resolve the current STT provider from config. Falls back to Apple Speech.
    var sttProvider: any STTProvider {
        resolvedSTTProvider(scopeID: config.activeModeID)
    }

    /// Resolve the current LLM service from config. Returns nil if not configured.
    var llmService: (any SpeechFlowLLMProvider)? {
        resolvedLLMProvider(scopeID: config.activeModeID)
    }

    /// Human-readable name of the current STT provider for UI display.
    var sttProviderName: String {
        if let frozenSTTProviderName { return frozenSTTProviderName }
        return resolvedSTTProviderName(scopeID: config.activeModeID)
    }

    /// Human-readable name of the current LLM provider for UI display.
    var llmProviderName: String? {
        if let frozenLLMProviderName { return frozenLLMProviderName }
        return resolvedLLMProviderName(scopeID: config.activeModeID)
    }

    private func resolvedSTTProvider(scopeID: String?) -> any STTProvider {
        if let test = _testSTT { return test }
        let profileID = config.effectiveSTTProfileID(forModeID: scopeID)
        return STTResolver.resolve(config: config, profileID: profileID)
    }

    private func resolvedLLMProvider(scopeID: String?) -> (any SpeechFlowLLMProvider)? {
        if let test = _testLLM { return test }

        let profileID = config.effectiveLLMProfileID(forModeID: scopeID)
        guard !profileID.isEmpty,
              let profile = config.modelProfiles.first(where: { $0.id == profileID }),
              profile.hasLLM else {
            return nil
        }
        let key = (try? KeychainStore(service: "com.fonos.models").get(profile.id)) ?? ""
        let baseURL = profile.baseURL ?? ""
        return LLMService(
            apiKey: key,
            modelID: profile.modelID,
            baseURL: baseURL.isEmpty ? "https://api.openai.com" : baseURL
        )
    }

    private func resolvedSTTProviderName(scopeID: String?) -> String {
        let profileID = config.effectiveSTTProfileID(forModeID: scopeID)
        guard !profileID.isEmpty,
              let profile = config.modelProfiles.first(where: { $0.id == profileID }),
              profile.hasSTT else {
            return "Apple Speech"
        }
        return profile.name
    }

    private func resolvedLLMProviderName(scopeID: String?) -> String? {
        let profileID = config.effectiveLLMProfileID(forModeID: scopeID)
        guard !profileID.isEmpty,
              let profile = config.modelProfiles.first(where: { $0.id == profileID }),
              profile.hasLLM else {
            return nil
        }
        return profile.name
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
        case (false, .recording):
            return .stop
        default:
            return .none
        }
    }

    // MARK: - Recording Control

    @MainActor
    func startRecording() {
        log.info("▶️ startRecording() called, isRecording=\(self.isRecording)")
        guard !isRecording else {
            log.warning("⚠️ Already recording, ignoring tap")
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

        cancelInFlightProcessing()
        resetFlowUI()

        // Set recording state immediately for responsive UI
        recordingState = .recording
        startLevelPolling()

        // Start audio engine on background thread to avoid blocking main thread
        audioCapture.startCapture { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    log.error("❌ Engine start failed: \(error.localizedDescription)")
                    self.recordingState = .error(message: error.localizedDescription)
                    self.stopLevelPolling()
                } else {
                    log.info("✅ Engine started successfully on background thread")
                }
            }
        }
    }

    @MainActor
    func stopRecording() {
        log.info("⏹ stopRecording() called")
        guard isRecording else { return }
        stopLevelPolling()

        // Stop engine and get WAV data
        let wavData = audioCapture.stopCapture()
        log.info("⏹ Got WAV data: \(wavData?.count ?? 0) bytes")
        finishRecording(wavData: wavData ?? Data())
    }

    /// Runs the STT → LLM pipeline on captured audio, updates UI state, and
    /// persists the completed session to History. Split from stopRecording so
    /// the post-capture pipeline is testable without audio hardware.
    @MainActor
    func finishRecording(wavData: Data) {
        let mode = self.currentMode
        let modeScopeID = config.activeModeID
        let sttLanguage = config.sttLanguage == "auto" ? nil : config.sttLanguage
        processingTask?.cancel()
        let processingID = UUID()
        let flow = resolveSpeechFlow(
            language: sttLanguage,
            mode: mode,
            scopeID: modeScopeID
        )

        if case .none(.notConfigured) = flow.postprocess {
            log.info("⚠️ Mode requires LLM but none configured, will use corrected transcript")
        }

        activeProcessingID = processingID
        frozenSTTProviderName = resolvedSTTProviderName(scopeID: modeScopeID)
        if case .llm = flow.postprocess {
            frozenLLMProviderName = resolvedLLMProviderName(scopeID: modeScopeID)
        } else {
            frozenLLMProviderName = nil
        }
        flowPresentation = SpeechFlowPresentation(runID: processingID, flow: flow)
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
                log.info("🔄 Starting STT transcription...")
                let result = try await executeSpeechFlow(
                    wavData,
                    flow: flow,
                    runID: processingID,
                    onEvent: { [weak self] event in
                        await self?.receiveFlowEvent(event)
                    }
                )
                guard activeProcessingID == processingID, !Task.isCancelled else { return }
                log.info("✅ Processing complete: \(result.text.prefix(50))...")
                flowPresentation.complete(
                    llmOutcome: result.llmOutcome,
                    degradation: result.degradation,
                    timings: result.timings
                )
                recordingState = .result(
                    transcript: result.rawTranscript,
                    processed: result.didProcessWithLLM ? result.text : nil
                )
                persistSession(result: result, mode: mode)
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
    }

    @MainActor
    private func resetFlowUI() {
        flowPresentation = .idle
        frozenSTTProviderName = nil
        frozenLLMProviderName = nil
        sttLatency = 0
        llmLatency = 0
    }

    @MainActor
    private func receiveFlowEvent(_ event: SpeechFlowEvent) {
        guard activeProcessingID == event.runID else { return }
        flowPresentation.apply(event)
    }

    /// Inserts a DictationSession into History. No-op when modelContext is unset.
    @MainActor
    private func persistSession(result: ProcessResult, mode: Mode) {
        guard let context = modelContext else { return }
        let session = DictationSession(
            date: Date(),
            mode: mode.id,
            inputText: result.rawTranscript,
            outputText: result.text,
            destination: config.autoSendDestination.isEmpty ? "clipboard" : config.autoSendDestination,
            latencyMs: result.timings.total * 1000
        )
        context.insert(session)
        do {
            try context.save()
        } catch {
            log.error("❌ Failed to persist session: \(error.localizedDescription)")
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
        let flow = await resolveSpeechFlow(
            language: language,
            mode: mode,
            scopeID: scopeID
        )

        return try await executeSpeechFlow(
            audioData,
            flow: flow,
            runID: UUID()
        )
    }

    private func executeSpeechFlow(
        _ audioData: Data,
        flow: ResolvedSpeechFlow,
        runID: UUID,
        onEvent: SpeechFlowEventHandler? = nil
    ) async throws -> ProcessResult {

        try Task.checkCancellation()
        let didResetMetrics = await MainActor.run {
            guard !Task.isCancelled else { return false }
            sttLatency = 0
            llmLatency = 0
            return true
        }
        guard didResetMetrics else { throw CancellationError() }

        let flowResult = try await SpeechFlowRunner().run(
            SpeechFlowInput(runID: runID, wavData: audioData),
            using: flow,
            onEvent: onEvent
        )

        try Task.checkCancellation()
        let didPublishMetrics = await MainActor.run {
            guard !Task.isCancelled else { return false }
            sttLatency = flowResult.timings.stt
            llmLatency = flowResult.timings.llm ?? 0
            return true
        }
        guard didPublishMetrics else { throw CancellationError() }

        return ProcessResult(
            text: flowResult.finalText,
            rawTranscript: flowResult.correctedTranscript,
            isRawFallback: flowResult.llmOutcome.isFallback,
            providerTranscript: flowResult.providerTranscript,
            didProcessWithLLM: flowResult.llmOutcome.producedProcessedText,
            llmOutcome: flowResult.llmOutcome,
            degradation: flowResult.degradation,
            timings: flowResult.timings
        )
    }

    /// Resolves mutable Settings/Keychain/vocab state as one MainActor
    /// transaction, then hands a Sendable snapshot to the generic executor.
    @MainActor
    private func resolveSpeechFlow(
        language: String?,
        mode: Mode,
        scopeID: String?
    ) -> ResolvedSpeechFlow {
        // `scopeID` stays distinct from Mode.id because custom ModeConfig ids
        // are UUIDs while Mode.id collapses every custom mode to "custom".
        let resolvedScopeID = scopeID ?? mode.id
        let resolvedSTT = resolvedSTTProvider(scopeID: resolvedScopeID)
        let resolvedLLM = resolvedLLMProvider(scopeID: resolvedScopeID)
        let vocab = SpeechFlowVocabSnapshot(
            context: vocabStore.context(modeID: resolvedScopeID)
        )
        let promptHint = config.modeConfigs
            .first(where: { $0.id == resolvedScopeID })?
            .sttPrompt ?? ""

        let postprocess: ResolvedSpeechFlow.Postprocess
        if !mode.requiresLLM {
            postprocess = .none(.notRequested)
        } else if let resolvedLLM {
            postprocess = .llm(
                .init(provider: resolvedLLM, mode: mode, failurePolicy: .useInput)
            )
        } else {
            postprocess = .none(.notConfigured)
        }

        return ResolvedSpeechFlow(
            flowID: "dictation:\(resolvedScopeID)",
            stt: .init(
                provider: resolvedSTT,
                language: language,
                promptHint: promptHint
            ),
            vocab: vocab,
            postprocess: postprocess
        )
    }
}
