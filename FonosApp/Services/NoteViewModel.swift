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

    @Published var recordingState: RecordingState = .idle {
        didSet { updateRecordingStopRoute() }
    }
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
    private var transcriptHandler: (@MainActor (String) -> Void)?
    private var appendTargetID: UUID?

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

    private func updateRecordingStopRoute() {
        if recordingState == .recording, let containerId = activeContainerID {
            RecordingStopRouter.shared.register(self) { [weak self] in
                self?.stopRecording(to: containerId)
            }
        } else {
            RecordingStopRouter.shared.unregister(self)
        }
    }

    /// With `onTranscribed`, the recording's text goes to that closure instead
    /// of into a new note, which is how an open note takes dictated text.
    /// `appendingTo` names that note, so a failed run can retry into it.
    func startRecording(
        to containerId: UUID,
        appendingTo entryID: UUID? = nil,
        onTranscribed: (@MainActor (String) -> Void)? = nil
    ) {
        PendingRecordingPlayer.shared.stop()
        guard activeContainerID == nil,
              (recordingState == .idle || {
            if case .done = recordingState { return true }
            if case .error = recordingState { return true }
            return false
        }()) else { return }
        activeContainerID = containerId
        transcriptHandler = onTranscribed
        appendTargetID = entryID
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
                    await self.recordAndStore(
                        to: containerId,
                        audioData: wavData,
                        appendingTo: self.appendTargetID,
                        onTranscribed: self.transcriptHandler
                    )
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

        // An empty capture must not be uploaded: the server cannot probe a
        // zero-byte file and answers HTTP 415 "Unsupported audio". It still
        // goes in the queue, as a 0:00 row, so the failure can be told apart
        // from a 415 on real audio.
        guard let wavData = audioCapture.stopCapture(), !wavData.isEmpty else {
            clearSavedForRetryFlag()
            recordingState = .processing
            let entryID = appendTargetID
            Task {
                let message = "No audio was captured (0 bytes)."
                await keepForRetry(
                    audio: Data(),
                    in: containerId,
                    appendingTo: entryID,
                    error: message,
                    permanent: true
                )
                recordingState = .error(message: message)
            }
            return
        }
        recordingState = .processing

        let onTranscribed = transcriptHandler
        let entryID = appendTargetID
        Task {
            await recordAndStore(
                to: containerId,
                audioData: wavData,
                appendingTo: entryID,
                onTranscribed: onTranscribed
            )
        }
    }

    // MARK: - Core workflow

    /// Compile the notebook's settings into a frozen voice workflow, execute it,
    /// then adapt the result into a NoteEntry. Dictate, keyboard and Notes now
    /// share provider resolution, vocabulary, correction, fallback and tracing.
    /// A failure keeps the audio so the notebook can retry it.
    func recordAndStore(
        to containerId: UUID,
        audioData: Data,
        appendingTo entryID: UUID? = nil,
        onTranscribed: (@MainActor (String) -> Void)? = nil
    ) async {
        clearSavedForRetryFlag()
        guard noteService.notebook(id: containerId) != nil else {
            recordingState = .error(message: "Notebook not found.")
            return
        }

        do {
            if let onTranscribed {
                let run = try await runRecipe(in: containerId, audioData: audioData)
                onTranscribed(Self.noteText(from: run.result, recipe: run.recipe))
            } else {
                _ = try await transcribeAndStore(to: containerId, audioData: audioData)
            }
            recordingState = .done
        } catch {
            noteVMLog.error("Notebook workflow failed: \(error.localizedDescription)")
            if PendingRecordingStore.shouldKeep(error: error, audio: audioData) {
                await keepForRetry(
                    audio: audioData,
                    in: containerId,
                    appendingTo: entryID,
                    error: error.localizedDescription,
                    permanent: PendingRecordingFailure.classify(error) == .permanent
                )
            }
            recordingState = .error(message: error.localizedDescription)
        }
    }

    /// Adds a failed recording to the retry queue, and flags it for the sheet.
    private func keepForRetry(
        audio: Data,
        in containerId: UUID,
        appendingTo entryID: UUID?,
        error message: String,
        permanent: Bool
    ) async {
        let store = pendingStore
        do {
            // Encoding a five-minute clip must not block the main actor.
            let saved = try await Task.detached(priority: .userInitiated) {
                try store.save(
                    wav: audio,
                    surface: .note,
                    notebookID: containerId,
                    noteEntryID: entryID,
                    error: message,
                    autoRetryStopped: permanent
                )
            }.value
            lastFailurePendingID = saved.id
            lastFailureSavedForRetry = true
        } catch {
            noteVMLog.error("Could not keep the recording for retry: \(error.localizedDescription)")
        }
    }

    /// True while a recording or its transcription is in progress.
    var isRunBusy: Bool {
        recordingState == .recording || recordingState == .processing
    }

    /// Retry from the notebook, compiled from its current settings: the text
    /// goes to the end of the note it was recorded for, or into a new note
    /// when it had none or that note is gone. Either way it is then copied.
    @discardableResult
    func retryPendingRecording(_ id: UUID, copy: Bool = true) async throws -> String {
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
            let text = try await transcribeAndStore(
                to: notebookID,
                audioData: audioData,
                appendingTo: pending.noteEntryID
            )
            pendingStore.discard(id: id)
            clearSavedForRetryFlag(for: id)
            if copy { copyText(text) }
            return text
        } catch {
            // A cancelled retry is not a failed attempt.
            if !(error is CancellationError) {
                pendingStore.recordAttempt(id: id, failure: error)
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

    /// Runs the notebook recipe and stores the text, at the end of `entryID`
    /// if that note still exists, otherwise as a new note. Returns the text.
    private func transcribeAndStore(
        to containerId: UUID,
        audioData: Data,
        appendingTo entryID: UUID? = nil
    ) async throws -> String {
        let run = try await runRecipe(in: containerId, audioData: audioData)
        if let entryID {
            let text = Self.noteText(from: run.result, recipe: run.recipe)
            if try noteService.appendToEntry(entryID, text: text) { return text }
        }
        let entry = try persist(run.result, recipe: run.recipe, to: containerId)
        return entry.processedText ?? entry.rawText
    }

    private func runRecipe(
        in containerId: UUID,
        audioData: Data
    ) async throws -> (result: VoiceWorkflowResult, recipe: NotebookPipeline.WorkflowRecipe) {
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
        return (result, recipe)
    }

    /// The LLM text when the recipe's LLM step succeeded, otherwise the
    /// transcript, which is what a stored note would show.
    private static func noteText(
        from result: VoiceWorkflowResult,
        recipe: NotebookPipeline.WorkflowRecipe
    ) -> String {
        recipe.hasLLM && result.degradations.isEmpty ? result.finalText : result.rawText
    }

    /// Adds dictated text to the end of a note, separated by one space unless
    /// the note is empty or already ends in whitespace.
    static func appending(_ addition: String, to text: String) -> String {
        guard !text.isEmpty, text.last?.isWhitespace == false else { return text + addition }
        return addition.isEmpty ? text : text + " " + addition
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
