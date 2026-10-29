// Notes keep the audio of a failed notebook run; the notebook's pending row
// retries it quietly (new note + copy).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingNoteTests

import Testing
import SwiftData
import Foundation
import AVFoundation
@testable import FonosApp

private final class SwitchableNoteSTT: STTProvider, @unchecked Sendable {
    var error: STTError?
    var transcript = "note text"

    init(error: STTError? = .networkUnavailable) { self.error = error }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        if let error { throw error }
        return transcript
    }
}

private final class DeniedCapture: AudioCapturing, @unchecked Sendable {
    var currentAudioLevel: Float = 0
    var isRecording = false
    var isStarting = false
    func micPermissionStatus() -> AVAudioSession.RecordPermission {
        AVAudioSession.RecordPermission(rawValue: UInt(AVAudioApplication.recordPermission.denied.rawValue))!
    }
    func requestMicPermission() async -> Bool { false }
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken { AudioCaptureStartToken() }
    @MainActor func stopCapture() -> Data? { nil }
}

private func makeTempStore() -> PendingRecordingStore {
    PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    )
}

private final class GatedNoteSTT: STTProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    func release() { lock.withLock { released = true } }
    private var isReleased: Bool { lock.withLock { released } }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        while !isReleased { try await Task.sleep(nanoseconds: 10_000_000) }
        return "gated text"
    }
}

@MainActor
private func makeNotes(_ stt: any STTProvider) throws
    -> (NoteViewModel, NoteService, NoteContainer, PendingRecordingStore) {
    let container = try ModelContainer(
        for: Schema([NoteContainer.self, NoteEntry.self]),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let service = NoteService(modelContainer: container)
    let notebook = try service.createNotebook(title: "Retry Notebook")
    let vm = NoteViewModel(noteService: service, sttProvider: stt, llmProvider: nil)
    let store = makeTempStore()
    vm.pendingStore = store
    vm.copyText = { _ in }
    return (vm, service, notebook, store)
}

@MainActor
struct PendingRecordingNoteTests {

    @Test("an STT failure keeps the audio for that notebook")
    func failureKeepsAudio() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))

        let pending = try #require(store.all().first)
        #expect(pending.surface == .note)
        #expect(pending.notebookID == notebook.id)
        #expect(vm.lastFailureSavedForRetry)
        if case .error = vm.recordingState {} else { Issue.record("expected error state") }
    }

    @Test("no speech and success keep nothing")
    func nothingKept() async throws {
        let stt = SwitchableNoteSTT(error: .noTranscript)
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        #expect(store.all().isEmpty)
        #expect(!vm.lastFailureSavedForRetry)

        stt.error = nil
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        #expect(store.all().isEmpty)
    }

    @Test("quiet retry adds the note, copies it and discards the item")
    func quietRetry() async throws {
        let stt = SwitchableNoteSTT()
        let (vm, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let id = try #require(store.all().first?.id)

        stt.error = nil
        let text = try await vm.retryPendingRecording(id)

        #expect(text == "note text")
        #expect(copied == ["note text"])
        #expect(store.all().isEmpty)
        #expect(service.entriesForNotebook(notebook.id).map(\.rawText) == ["note text"])
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("a retry that fails again counts the attempt")
    func retryFailsAgain() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let id = try #require(store.all().first?.id)

        await #expect(throws: STTError.networkUnavailable) {
            try await vm.retryPendingRecording(id)
        }
        #expect(store.recording(id: id)?.attempts == 1)
    }

    @Test("a retry whose notebook is gone reports it and keeps the item")
    func missingNotebook() async throws {
        let (vm, _, _, store) = try makeNotes(SwitchableNoteSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: Data(count: 44), surface: .note, notebookID: UUID(), error: "e")

        await #expect(throws: PendingRecordingError.notebookUnavailable) {
            try await vm.retryPendingRecording(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 1)
    }

    @Test("a cancelled retry is not a failed attempt")
    func cancelledRetryNotCounted() async throws {
        let stt = GatedNoteSTT()
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: Data(count: 44), surface: .note, notebookID: notebook.id, error: "e")

        let task = Task { try await vm.retryPendingRecording(saved.id) }
        while !vm.retryingPendingIDs.contains(saved.id) { await Task.yield() }
        task.cancel()
        _ = try? await task.value

        #expect(store.recording(id: saved.id)?.attempts == 0)
        #expect(vm.retryingPendingIDs.isEmpty)
    }

    @Test("discard is refused while the item is being retried")
    func discardRefusedMidRetry() async throws {
        let stt = GatedNoteSTT()
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: Data(count: 44), surface: .note, notebookID: notebook.id, error: "e")

        let task = Task { try await vm.retryPendingRecording(saved.id) }
        while !vm.retryingPendingIDs.contains(saved.id) { await Task.yield() }
        #expect(!vm.discardPendingRecording(saved.id))
        #expect(store.recording(id: saved.id) != nil)

        stt.release()
        _ = try await task.value
        #expect(store.recording(id: saved.id) == nil)
        #expect(vm.discardPendingRecording(saved.id))
    }

    @Test("a second retry of the same item is rejected")
    func doubleRetryRejected() async throws {
        let stt = GatedNoteSTT()
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: Data(count: 44), surface: .note, notebookID: notebook.id, error: "e")

        let task = Task { try await vm.retryPendingRecording(saved.id) }
        while !vm.retryingPendingIDs.contains(saved.id) { await Task.yield() }
        await #expect(throws: PendingRecordingError.alreadyRetrying) {
            try await vm.retryPendingRecording(saved.id)
        }
        stt.release()
        _ = try await task.value
    }

    @Test("the saved-for-retry message clears after a successful retry")
    func flagClearsOnRetrySuccess() async throws {
        let stt = SwitchableNoteSTT()
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let id = try #require(store.all().first?.id)
        #expect(vm.lastFailureSavedForRetry)

        stt.error = nil
        try await vm.retryPendingRecording(id)
        #expect(!vm.lastFailureSavedForRetry)
    }

    @Test("the saved-for-retry message clears when its item is discarded, not another")
    func flagClearsOnDiscard() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let other = try store.save(wav: Data(count: 44), surface: .note, notebookID: notebook.id, error: "e")
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let id = try #require(store.all().first { $0.id != other.id }?.id)

        vm.discardPendingRecording(other.id)
        #expect(vm.lastFailureSavedForRetry == true)
        vm.discardPendingRecording(id)
        #expect(!vm.lastFailureSavedForRetry)
    }

    @Test("a later unrelated error does not show the saved-for-retry message")
    func flagClearsOnLaterError() async throws {
        let container = try ModelContainer(
            for: Schema([NoteContainer.self, NoteEntry.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = NoteService(modelContainer: container)
        let notebook = try service.createNotebook(title: "N")
        let vm = NoteViewModel(noteService: service, sttProvider: SwitchableNoteSTT(),
                               llmProvider: nil, audioCapture: DeniedCapture())
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        vm.pendingStore = store
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        #expect(vm.lastFailureSavedForRetry)

        vm.startRecording(to: notebook.id)
        #expect(vm.recordingState == .error(message: "Microphone permission denied."))
        #expect(!vm.lastFailureSavedForRetry)
    }

    @Test("a second failure replaces the first; retrying another item keeps the flag")
    func secondFailureReplacesFirst() async throws {
        let stt = SwitchableNoteSTT()
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let first = try #require(store.all().first?.id)
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))
        let second = try #require(store.all().first { $0.id != first }?.id)

        // The flag now tracks the second item only.
        stt.error = nil
        try await vm.retryPendingRecording(first)
        #expect(vm.lastFailureSavedForRetry == true)
        vm.discardPendingRecording(second)
        #expect(!vm.lastFailureSavedForRetry)
    }
}
