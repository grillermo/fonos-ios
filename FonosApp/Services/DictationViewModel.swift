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
    /// The original STT transcript, before any LLM processing.
    let rawTranscript: String
    /// True if LLM processing failed and we fell back to the raw STT transcript.
    let isRawFallback: Bool

    init(text: String, rawTranscript: String? = nil, isRawFallback: Bool = false) {
        self.text = text
        self.rawTranscript = rawTranscript ?? text
        self.isRawFallback = isRawFallback
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

    /// Current mode — derived from config.activeModeID
    var currentMode: Mode {
        get {
            switch config.activeModeID {
            case "raw": return .raw
            case "polish": return .polish
            case "formal": return .formal
            case "translate": return .translate(targetLanguage: config.translateTargetLanguage)
            default:
                // Check custom modes
                if let custom = config.modeConfigs.first(where: { $0.id == config.activeModeID }) {
                    return custom.mode
                }
                return .raw
            }
        }
        set {
            config.activeModeID = newValue.id
        }
    }

    /// Convenience for views/tests: true when actively recording.
    var isRecording: Bool {
        if case .recording = recordingState { return true }
        return false
    }

    // MARK: - Services

    private let audioCapture: AudioCaptureService
    private var levelPollTimer: Timer?

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
    private var _testLLM: LLMService?
    init(sttProvider: (any STTProvider)?,
         llmService: LLMService? = nil,
         audioCapture: AudioCaptureService = AudioCaptureService()) {
        self._testSTT = sttProvider
        self._testLLM = llmService
        self.audioCapture = audioCapture
    }

    // MARK: - Provider Resolution

    /// Resolve the current STT provider from config. Falls back to Apple Speech.
    var sttProvider: any STTProvider {
        if let test = _testSTT { return test }
        return STTResolver.resolve(config: config)
    }

    /// Resolve the current LLM service from config. Returns nil if not configured.
    var llmService: LLMService? {
        if let test = _testLLM { return test }

        let profileID = config.llmProfile
        guard !profileID.isEmpty, let profile = config.modelProfiles.first(where: { $0.id == profileID }) else {
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

    /// Human-readable name of the current STT provider for UI display.
    var sttProviderName: String {
        let profileID = config.sttProfile
        if !profileID.isEmpty, let profile = config.modelProfiles.first(where: { $0.id == profileID }) {
            return profile.name
        }
        return "Apple Speech"
    }

    /// Human-readable name of the current LLM provider for UI display.
    var llmProviderName: String? {
        let profileID = config.llmProfile
        guard !profileID.isEmpty, let profile = config.modelProfiles.first(where: { $0.id == profileID }) else {
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

        if mode.requiresLLM && llmService == nil {
            // Show transcript only — no LLM configured
            log.info("⚠️ Mode requires LLM but none configured, will use raw transcript")
        }

        recordingState = .processing

        Task {
            do {
                log.info("🔄 Starting STT transcription...")
                let sttLang = config.sttLanguage == "auto" ? nil : config.sttLanguage
                let result = try await processAudio(
                    wavData,
                    language: sttLang,
                    mode: mode
                )
                log.info("✅ Processing complete: \(result.text.prefix(50))...")
                await MainActor.run {
                    recordingState = .result(
                        transcript: result.rawTranscript,
                        processed: result.isRawFallback ? nil : result.text
                    )
                    persistSession(result: result, mode: mode)
                }
            } catch {
                log.error("❌ Processing failed: \(error.localizedDescription)")
                await MainActor.run {
                    recordingState = .error(message: error.localizedDescription)
                }
            }
        }
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
            latencyMs: (sttLatency + llmLatency) * 1000
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
    /// If LLM processing fails, falls back to the raw transcript.
    func processAudio(_ audioData: Data,
                      language: String?,
                      mode: Mode) async throws -> ProcessResult {
        // Vocab stages (P1-1): ① STT biasing ② deterministic corrections ③ LLM glossary
        let books = vocabStore.effectiveBooks(modeID: mode.id)
        let terms = VocabApplier.collectTerms(books)

        let sttStart = Date()
        let sttText = try await sttProvider.transcribe(
            audioData: audioData, language: language, vocabulary: terms
        )
        let sttElapsed = Date().timeIntervalSince(sttStart)
        await MainActor.run { sttLatency = sttElapsed }

        let rawTranscript = VocabApplier.applyRules(sttText, books: books)

        // Raw mode or no LLM: return transcript directly
        guard mode.requiresLLM, let llm = llmService else {
            return ProcessResult(text: rawTranscript, isRawFallback: false)
        }

        let llmStart = Date()
        do {
            let processed = try await llm.process(
                text: rawTranscript, mode: mode,
                glossary: VocabApplier.buildGlossaryBlock(terms: terms)
            )
            let llmElapsed = Date().timeIntervalSince(llmStart)
            await MainActor.run { llmLatency = llmElapsed }
            return ProcessResult(text: processed, rawTranscript: rawTranscript, isRawFallback: false)
        } catch {
            // LLM failure — fall back to raw transcript
            let llmElapsed = Date().timeIntervalSince(llmStart)
            await MainActor.run { llmLatency = llmElapsed }
            return ProcessResult(text: rawTranscript, isRawFallback: true)
        }
    }
}
