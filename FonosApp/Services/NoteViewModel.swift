import Foundation
import SwiftUI
import os.log

private let noteVMLog = Logger(subsystem: "com.fonos.ios", category: "NoteViewModel")

// MARK: - NoteViewModel

/// Orchestrates the recording → transcription → storage pipeline for voice notes.
/// Follows the DictationViewModel pattern for provider resolution and audio level polling.
@MainActor
final class NoteViewModel: ObservableObject, @unchecked Sendable {

    // MARK: - Recording State

    enum RecordingState: Equatable {
        case idle
        case recording
        case processing
        case done
        case error(message: String)
    }

    @Published var recordingState: RecordingState = .idle
    @Published var audioLevel: Float = 0

    /// True while permission is pending or capture owns a frozen notebook.
    /// This closes the brief `.idle` window during the system permission sheet
    /// so a second deep link cannot retarget an in-flight recording.
    var isCapturePendingOrActive: Bool { activeContainerID != nil }

    // MARK: - Services

    private let noteService: NoteService
    private let audioCapture: any AudioCapturing
    private var levelPollTimer: Timer?
    private var activeContainerID: UUID?

    // MARK: - Injected providers (for tests)

    private var _testSTT: (any STTProvider)?
    private var _testLLM: (any VoiceWorkflowLLMProvider)?

    // MARK: - Config (for production provider resolution)

    var config: AppConfig = AppConfig()

    /// Vocab books + mounts (P1-1): global ∪ notebook mounts feed STT biasing,
    /// deterministic corrections, and the notebook LLM glossary.
    var vocabStore = VocabStore()

    // MARK: - Init (production)

    init(noteService: NoteService, audioCapture: any AudioCapturing = AudioCaptureService()) {
        self.noteService = noteService
        self.audioCapture = audioCapture
    }

    /// Test/injection initialiser. Overrides are frozen into the same workflow
    /// plan used in production rather than selecting a separate test pipeline.
    init(noteService: NoteService,
         sttProvider: (any STTProvider)?,
         llmProvider: (any VoiceWorkflowLLMProvider)?,
         audioCapture: any AudioCapturing = AudioCaptureService()) {
        self.noteService = noteService
        self._testSTT = sttProvider
        self._testLLM = llmProvider
        self.audioCapture = audioCapture
    }

    // MARK: - Recording Control

    func startRecording(to containerId: UUID) {
        guard activeContainerID == nil,
              (recordingState == .idle || {
            if case .done = recordingState { return true }
            if case .error = recordingState { return true }
            return false
        }()) else { return }
        activeContainerID = containerId

        let permission = audioCapture.micPermissionStatus()
        switch permission {
        case .granted:
            doStartCapture(to: containerId)
        case .undetermined:
            Task { @MainActor in
                let granted = await audioCapture.requestMicPermission()
                if granted, activeContainerID == containerId {
                    doStartCapture(to: containerId)
                } else {
                    activeContainerID = nil
                    recordingState = .error(message: "Microphone permission is required.")
                }
            }
        case .denied:
            activeContainerID = nil
            recordingState = .error(message: "Microphone permission denied.")
        @unknown default:
            activeContainerID = nil
            recordingState = .error(message: "Microphone permission unavailable.")
        }
    }

    private func doStartCapture(to containerId: UUID) {
        recordingState = .recording
        startLevelPolling()
        audioCapture.startCapture(
            onInterruption: { [weak self] in
                Task { @MainActor in
                    guard let self, self.activeContainerID == containerId else { return }
                    self.activeContainerID = nil
                    self.stopLevelPolling()
                    self.recordingState = .error(message: "Recording was interrupted.")
                }
            },
            onMaximumDurationReached: { [weak self] wavData in
                Task { @MainActor in
                    guard let self, self.activeContainerID == containerId else { return }
                    self.activeContainerID = nil
                    self.stopLevelPolling()
                    guard let wavData, !wavData.isEmpty else {
                        self.recordingState = .error(
                            message: "Recording reached the five-minute limit, but the audio could not be finalized."
                        )
                        return
                    }
                    self.recordingState = .processing
                    await self.recordAndStore(to: containerId, audioData: wavData)
                }
            },
            completion: { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.activeContainerID = nil
                        self.recordingState = .error(message: error.localizedDescription)
                        self.stopLevelPolling()
                    }
                }
            }
        )
    }

    func stopRecording(to containerId: UUID) {
        guard case .recording = recordingState else { return }
        stopLevelPolling()
        activeContainerID = nil

        let wavData = audioCapture.stopCapture() ?? Data()
        recordingState = .processing

        Task {
            await recordAndStore(to: containerId, audioData: wavData)
        }
    }

    // MARK: - Core workflow

    /// Compile the notebook's settings into a frozen voice workflow, execute it,
    /// then adapt the result into a NoteEntry. Dictate, keyboard and Notes now
    /// share provider resolution, vocabulary, correction, fallback and tracing.
    func recordAndStore(to containerId: UUID, audioData: Data) async {
        guard let notebook = noteService.notebook(id: containerId) else {
            recordingState = .error(message: "Notebook not found.")
            return
        }
        let recipe = NotebookPipeline.workflowRecipe(for: notebook)

        do {
            let factory = VoiceWorkflowPlanFactory(
                config: config,
                vocabStore: vocabStore,
                sttProviderOverride: _testSTT,
                llmProviderOverride: _testLLM,
                effectiveVocabularyBooks: vocabStore.effectiveBooks(notebookID: containerId)
            )
            let compilation = try factory.compile(
                definition: recipe.definition,
                catalog: recipe.catalog,
                legacyScopeID: nil,
                supportedOutputTypes: ["return_to_caller"],
                resolveOutput: { _ in ReturnToCallerVoiceWorkflowOutput() }
            )
            let result = try await VoiceWorkflowEngine().run(
                VoiceWorkflowRunInput(audioData: audioData),
                using: compilation.plan
            )
            try persist(result, recipe: recipe, to: containerId)
            recordingState = .done
        } catch {
            noteVMLog.error("Notebook workflow failed: \(error.localizedDescription)")
            recordingState = .error(message: error.localizedDescription)
        }
    }

    private func persist(
        _ result: VoiceWorkflowResult,
        recipe: NotebookPipeline.WorkflowRecipe,
        to containerId: UUID
    ) throws {
        let processedText = recipe.hasLLM && result.degradations.isEmpty
            ? result.finalText
            : nil
        try noteService.addEntry(
            to: containerId,
            rawText: result.rawText,
            processedText: processedText,
            mode: recipe.hasLLM ? "llm" : "raw",
            language: recipe.language
        )
    }

    // MARK: - Audio Level Polling

    private func startLevelPolling() {
        levelPollTimer?.invalidate()
        levelPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // This timer is created by the @MainActor view model, so it is
            // attached to the main run loop. Make that executor guarantee
            // explicit to Swift 6 without spawning an untracked Task per tick.
            MainActor.assumeIsolated {
                guard let self else { return }
                let level = self.audioCapture.currentAudioLevel
                if abs(self.audioLevel - level) > 0.01 {
                    self.audioLevel = level
                }
            }
        }
    }

    private func stopLevelPolling() {
        levelPollTimer?.invalidate()
        levelPollTimer = nil
        audioLevel = 0
    }
}
