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
}
