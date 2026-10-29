// Dictate keeps the audio of a failed run and retries it from the error card
// (full recipe) or from History (quiet: save + copy, no outputs).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingDictationTests

import Testing
import SwiftData
import Foundation
@testable import FonosApp

private final class SwitchableSTT: STTProvider, @unchecked Sendable {
    var error: STTError?
    var transcript = "hello again"

    init(error: STTError? = .networkUnavailable) { self.error = error }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        if let error { throw error }
        return transcript
    }
}

private func makeTempStore() -> PendingRecordingStore {
    PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    )
}

@MainActor
private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
        for: Schema([DictationSession.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

private func dummyWAV() -> Data { Data(count: 44) }

@MainActor
private func waitUntil(
    _ vm: DictationViewModel,
    timeout: TimeInterval = 5,
    _ done: (DictationViewModel.RecordingState) -> Bool
) async throws {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if done(vm.recordingState) { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("Timed out; state is \(vm.recordingState)")
}

private func isError(_ state: DictationViewModel.RecordingState) -> Bool {
    if case .error = state { return true }
    return false
}

private func isResult(_ state: DictationViewModel.RecordingState) -> Bool {
    if case .result = state { return true }
    return false
}

@MainActor
private func makeViewModel(_ stt: SwitchableSTT) -> (DictationViewModel, PendingRecordingStore) {
    let vm = DictationViewModel(sttProvider: stt)
    let store = makeTempStore()
    vm.pendingStore = store
    vm.copyText = { _ in }
    return (vm, store)
}

@Suite(.serialized)
struct PendingRecordingDictationTests {

    @Test("an STT failure keeps the audio and points the error card at it")
    @MainActor
    func failureKeepsAudio() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)

        let pending = try #require(store.all().first)
        #expect(pending.surface == .dictate)
        #expect(pending.workflowID == "wf.dictation")
        #expect(vm.lastPendingRecordingID == pending.id)
        #expect(try store.audio(id: pending.id) == dummyWAV())
    }

    @Test("no speech keeps nothing")
    @MainActor
    func noSpeechKeepsNothing() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: .noTranscript))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
    }

    @Test("a failure after text reached History keeps nothing")
    @MainActor
    func failureAfterPersistKeepsNothing() {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.activeRunPersistedText = true
        vm.handleMainRunFailure(
            DestinationError.destinationUnavailable("Shortcut"),
            wavData: dummyWAV(),
            workflowID: "wf.dictation",
            retryingPendingID: nil
        )
        #expect(store.all().isEmpty)
    }

    @Test("a successful run keeps nothing")
    @MainActor
    func successKeepsNothing() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isResult)
        #expect(store.all().isEmpty)
    }

    private func processed(_ id: UUID = UUID()) -> VoiceWorkflowProcessedResult {
        VoiceWorkflowProcessedResult(
            runID: id,
            workflowID: "wf.dictation",
            providerTranscript: "hi",
            rawText: "hi",
            finalText: "hi",
            degradations: [],
            timings: VoiceWorkflowTimings(steps: [], total: 0)
        )
    }

    private var definition: WorkflowDefinition {
        WorkflowDefinition(id: "wf.dictation", name: "Dictation", source: "mic", outputs: [])
    }

    @Test("persistSession sets the flag once the session is saved")
    @MainActor
    func persistSessionSetsFlag() throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let container = try makeContainer()
        vm.modelContext = container.mainContext
        vm.persistSession(processed: processed(), definition: definition, destination: "x")
        #expect(vm.activeRunPersistedText)
        #expect(vm.lastSession != nil)
    }

    @Test("persistSession without a context leaves the flag false")
    @MainActor
    func persistSessionWithoutContext() {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.modelContext = nil
        vm.persistSession(processed: processed(), definition: definition, destination: "x")
        #expect(!vm.activeRunPersistedText)
        #expect(vm.lastSession == nil)
    }

    @Test("a failed retry records the attempt and points the card at it")
    @MainActor
    func retryFailureRecordsAttempt() throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "old")
        vm.handleMainRunFailure(
            STTError.networkUnavailable,
            wavData: dummyWAV(),
            workflowID: "wf.dictation",
            retryingPendingID: saved.id
        )
        let after = try #require(store.recording(id: saved.id))
        #expect(after.attempts == 1)
        #expect(vm.lastPendingRecordingID == saved.id)
    }

    @Test("a retry that failed after text was persisted discards the item")
    @MainActor
    func retryFailureAfterPersistDiscards() throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "old")
        vm.lastPendingRecordingID = saved.id
        vm.activeRunPersistedText = true
        vm.handleMainRunFailure(
            DestinationError.destinationUnavailable("Shortcut"),
            wavData: dummyWAV(),
            workflowID: "wf.dictation",
            retryingPendingID: saved.id
        )
        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
    }

    @Test("a successful retry discards the item and clears the card id")
    @MainActor
    func retrySuccessDiscards() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "old")
        vm.lastPendingRecordingID = saved.id
        let prepared = try vm.prepareNextMainWorkflow()
        vm.runMainWorkflow(prepared, wavData: dummyWAV(), retryingPendingID: saved.id)
        try await waitUntil(vm, isResult)
        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
    }

    @Test("Retry now runs the recipe on the saved audio and discards it on success")
    @MainActor
    func fullRetrySucceeds() async throws {
        let stt = SwitchableSTT()
        let (vm, store) = makeViewModel(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let id = try #require(vm.lastPendingRecordingID)

        stt.error = nil
        vm.retryPendingRecording(id)
        try await waitUntil(vm, isResult)

        #expect(vm.recordingState == .result(transcript: "hello again", processed: nil))
        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
    }

    @Test("a retry that fails again keeps the item and counts the attempt")
    @MainActor
    func fullRetryFailsAgain() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let id = try #require(vm.lastPendingRecordingID)

        vm.retryPendingRecording(id)
        try await waitUntil(vm, isError)

        #expect(store.recording(id: id)?.attempts == 1)
        #expect(store.all().count == 1)
        #expect(vm.lastPendingRecordingID == id)
    }

    @Test("a retry whose recipe is gone reports it and keeps the item")
    @MainActor
    func retryMissingRecipe() throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.deleted", error: "e")

        vm.retryPendingRecording(saved.id)

        #expect(vm.recordingState == .error(message: PendingRecordingError.recipeUnavailable.errorDescription!))
        #expect(store.recording(id: saved.id)?.attempts == 1)
        #expect(vm.lastPendingRecordingID == saved.id)
    }

    @Test("a retry of an item that no longer exists reports it and leaves no stale id")
    @MainActor
    func retryUnknownID() {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.lastPendingRecordingID = UUID()

        vm.retryPendingRecording(UUID())

        #expect(vm.recordingState == .error(message: PendingRecordingError.notFound.errorDescription!))
        #expect(vm.lastPendingRecordingID == nil)
    }

    @Test("a retry is ignored while another run is active")
    @MainActor
    func retryIgnoredWhenBusy() throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        vm.recordingState = .processing
        vm.retryPendingRecording(saved.id)
        #expect(vm.recordingState == .processing)
        #expect(store.recording(id: saved.id)?.attempts == 0)
    }

    @Test("quiet retry saves to History, copies, discards, and leaves the Dictate state alone")
    @MainActor
    func quietRetry() async throws {
        let container = try makeContainer()
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.modelContext = container.mainContext
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        let text = try await vm.retryPendingRecordingQuietly(saved.id)

        #expect(text == "hello again")
        #expect(copied == ["hello again"])
        #expect(store.all().isEmpty)
        #expect(vm.recordingState == .idle)
        #expect(vm.lastSession == nil)
        #expect(vm.retryingPendingIDs.isEmpty)
        #expect(store.recording(id: saved.id) == nil)
        let sessions = try container.mainContext.fetch(FetchDescriptor<DictationSession>())
        #expect(sessions.map(\.outputText) == ["hello again"])
        #expect(sessions.first?.workflowID == "wf.dictation")
    }

    @Test("quiet retry keeps the audio when the text could not be saved to History")
    @MainActor
    func quietRetryNotPersisted() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.modelContext = nil
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        let text = try await vm.retryPendingRecordingQuietly(saved.id)

        #expect(text == "hello again")
        #expect(copied == ["hello again"])
        #expect(store.recording(id: saved.id) != nil)
    }

    @Test("a quiet retry that fails counts the attempt and rethrows")
    @MainActor
    func quietRetryFails() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        await #expect(throws: STTError.networkUnavailable) {
            try await vm.retryPendingRecordingQuietly(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 1)
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("a quiet retry is refused while Dictate is busy and does not count an attempt")
    @MainActor
    func quietRetryBusy() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        vm.recordingState = .processing

        await #expect(throws: PendingRecordingError.dictationBusy) {
            try await vm.retryPendingRecordingQuietly(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 0)
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("a quiet retry of a missing recipe throws and counts the attempt")
    @MainActor
    func quietRetryMissingRecipe() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.deleted", error: "e")

        await #expect(throws: PendingRecordingError.recipeUnavailable) {
            try await vm.retryPendingRecordingQuietly(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 1)
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("discard from the error card removes the item and returns to idle")
    @MainActor
    func discardFromCard() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let id = try #require(vm.lastPendingRecordingID)

        vm.discardPendingRecording(id)

        #expect(store.all().isEmpty)
        #expect(vm.lastPendingRecordingID == nil)
        #expect(vm.recordingState == .idle)
    }

    @Test("discarding another item leaves the error card alone")
    @MainActor
    func discardOtherItem() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.finishRecording(wavData: dummyWAV())
        try await waitUntil(vm, isError)
        let cardID = try #require(vm.lastPendingRecordingID)
        let other = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        vm.discardPendingRecording(other.id)

        #expect(store.recording(id: other.id) == nil)
        #expect(store.recording(id: cardID) != nil)
        #expect(vm.lastPendingRecordingID == cardID)
        #expect(isError(vm.recordingState))
    }

    @Test("an error after the text reached History discards the audio without counting an attempt")
    @MainActor
    func quietFailureAfterSave() throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        vm.handleQuietRetryFailure(STTError.networkUnavailable, id: saved.id, textSaved: true)
        #expect(store.recording(id: saved.id) == nil)
    }

    @Test("an error before the text was saved counts an attempt; a cancellation does not")
    @MainActor
    func quietFailureBeforeSave() throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        vm.handleQuietRetryFailure(CancellationError(), id: saved.id, textSaved: false)
        #expect(store.recording(id: saved.id)?.attempts == 0)
        vm.handleQuietRetryFailure(STTError.networkUnavailable, id: saved.id, textSaved: false)
        #expect(store.recording(id: saved.id)?.attempts == 1)
    }

    @Test("a cancelled quiet retry counts no attempt and keeps the audio")
    @MainActor
    func quietRetryCancelled() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        var copied: [String] = []
        vm.copyText = { copied.append($0) }

        let task = Task { @MainActor in try await vm.retryPendingRecordingQuietly(saved.id) }
        task.cancel()
        _ = try? await task.value

        #expect(copied.isEmpty)
        #expect(store.recording(id: saved.id)?.attempts == 0)
        #expect(store.recording(id: saved.id) != nil)
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("discard is refused while the item is being retried, and works after")
    @MainActor
    func discardDuringRetryRefused() async throws {
        let stt = SwitchableSTT(error: nil)
        let (vm, store) = makeViewModel(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        vm.retryPendingRecording(saved.id)
        #expect(vm.retryingPendingIDs.contains(saved.id))
        #expect(vm.discardPendingRecording(saved.id) == false)
        #expect(store.recording(id: saved.id) != nil)

        try await waitUntil(vm, isResult)
        #expect(vm.retryingPendingIDs.isEmpty)
        #expect(store.all().isEmpty)
    }

    @Test("a full retry in flight refuses a quiet retry of the same item")
    @MainActor
    func fullAndQuietOverlap() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")

        vm.retryPendingRecording(saved.id)
        // The run is also what makes Dictate busy, so either guard may fire.
        await #expect(throws: (any Error).self) {
            try await vm.retryPendingRecordingQuietly(saved.id)
        }
        try await waitUntil(vm, isResult)
        #expect(store.recording(id: saved.id) == nil)
    }

    @Test("a failed full retry releases the item and a failed start releases it too")
    @MainActor
    func fullRetryReleasesItem() async throws {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: dummyWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        vm.retryPendingRecording(saved.id)
        try await waitUntil(vm, isError)
        #expect(vm.retryingPendingIDs.isEmpty)
        #expect(vm.discardPendingRecording(saved.id))
        #expect(store.all().isEmpty)
    }

    @Test("a retry failure for an item discarded meanwhile leaves no stale card id")
    @MainActor
    func failureForVanishedItem() {
        let (vm, store) = makeViewModel(SwitchableSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.handleMainRunFailure(
            STTError.networkUnavailable,
            wavData: dummyWAV(),
            workflowID: "wf.dictation",
            retryingPendingID: UUID()
        )
        #expect(vm.lastPendingRecordingID == nil)
    }
}
