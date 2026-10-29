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

    // MARK: - Pending recordings

    /// Failed recordings kept for retry. Tests swap in a temporary store.
    var pendingStore = PendingRecordingStore.shared

    /// True when the last failure kept its audio, so the sheet can say so.
    /// Cleared when that item is retried successfully or discarded, so the
    /// sheet never claims audio that no longer exists.
    @Published var lastFailureSavedForRetry = false
    private var lastFailurePendingID: UUID?

    /// Pending recordings being retried, for row spinners.
    @Published var retryingPendingIDs: Set<UUID> = []

    /// Retries copy their text. Tests replace this.
    var copyText: @MainActor (String) -> Void = { UIPasteboard.general.string = $0 }

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
        clearSavedForRetryFlag()

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
                    clearSavedForRetryFlag()
                    recordingState = .error(message: "Microphone permission is required.")
                }
            }
        case .denied:
            activeContainerID = nil
            clearSavedForRetryFlag()
            recordingState = .error(message: "Microphone permission denied.")
        @unknown default:
            activeContainerID = nil
            clearSavedForRetryFlag()
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
                    self.clearSavedForRetryFlag()
                    self.recordingState = .error(message: "Recording was interrupted.")
                }
            },
            onMaximumDurationReached: { [weak self] wavData in
                Task { @MainActor in
                    guard let self, self.activeContainerID == containerId else { return }
                    self.activeContainerID = nil
                    self.stopLevelPolling()
                    guard let wavData, !wavData.isEmpty else {
                        self.clearSavedForRetryFlag()
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
                        self.clearSavedForRetryFlag()
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
    /// A failure keeps the audio so the notebook can retry it.
    func recordAndStore(to containerId: UUID, audioData: Data) async {
        clearSavedForRetryFlag()
        guard noteService.notebook(id: containerId) != nil else {
            recordingState = .error(message: "Notebook not found.")
            return
        }

        do {
            _ = try await transcribeAndStore(to: containerId, audioData: audioData)
            recordingState = .done
        } catch {
            noteVMLog.error("Notebook workflow failed: \(error.localizedDescription)")
            if PendingRecordingStore.shouldKeep(error: error, audio: audioData) {
                do {
                    let saved = try pendingStore.save(
                        wav: audioData,
                        surface: .note,
                        notebookID: containerId,
                        error: error.localizedDescription
                    )
                    lastFailurePendingID = saved.id
                    lastFailureSavedForRetry = true
                } catch {
                    noteVMLog.error("Could not keep the recording for retry: \(error.localizedDescription)")
                }
            }
            recordingState = .error(message: error.localizedDescription)
        }
    }

    /// Retry from the notebook: a new note from the saved audio, compiled
    /// from the notebook's current settings, then copied.
    @discardableResult
    func retryPendingRecording(_ id: UUID) async throws -> String {
        guard !retryingPendingIDs.contains(id) else { throw PendingRecordingError.alreadyRetrying }
        guard let pending = pendingStore.recording(id: id) else { throw PendingRecordingError.notFound }
        retryingPendingIDs.insert(id)
        defer { retryingPendingIDs.remove(id) }

        do {
            guard let notebookID = pending.notebookID,
                  noteService.notebook(id: notebookID) != nil else {
                throw PendingRecordingError.notebookUnavailable
            }
            let audioData = try pendingStore.audio(id: id)
            let text = try await transcribeAndStore(to: notebookID, audioData: audioData)
            pendingStore.discard(id: id)
            clearSavedForRetryFlag(for: id)
            copyText(text)
            return text
        } catch {
            // A cancelled retry is not a failed attempt.
            if !(error is CancellationError) {
                pendingStore.recordAttempt(id: id, error: error.localizedDescription)
            }
            throw error
        }
    }

    /// Returns false, changing nothing, while the item is being retried.
    @discardableResult
    func discardPendingRecording(_ id: UUID) -> Bool {
        guard !retryingPendingIDs.contains(id) else { return false }
        pendingStore.discard(id: id)
        clearSavedForRetryFlag(for: id)
        return true
    }

    /// Forgets which failure was kept, so the record sheet's "saved for
    /// retry" message only ever accompanies the failure that was saved.
    private func clearSavedForRetryFlag() {
        lastFailurePendingID = nil
        lastFailureSavedForRetry = false
    }

    private func clearSavedForRetryFlag(for id: UUID) {
        if lastFailurePendingID == id {
            lastFailurePendingID = nil
            lastFailureSavedForRetry = false
        }
    }

    /// Runs the notebook recipe and stores the note. Returns the note's text.
    private func transcribeAndStore(to containerId: UUID, audioData: Data) async throws -> String {
        guard let notebook = noteService.notebook(id: containerId) else {
            throw PendingRecordingError.notebookUnavailable
        }
        let recipe = NotebookPipeline.workflowRecipe(for: notebook)
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
        let entry = try persist(result, recipe: recipe, to: containerId)
        return entry.processedText ?? entry.rawText
    }

    private func persist(
        _ result: VoiceWorkflowResult,
        recipe: NotebookPipeline.WorkflowRecipe,
        to containerId: UUID
    ) throws -> NoteEntry {
        let processedText = recipe.hasLLM && result.degradations.isEmpty
            ? result.finalText
            : nil
        return try noteService.addEntry(
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
