// Notes keep the audio of a failed notebook run; the notebook's pending row
// retries it quietly: into the note it was recorded for, or a new note, then
// copied.
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
    var receivedAudio: Data?

    init(error: STTError? = .networkUnavailable) { self.error = error }

    func transcribe(audioData: Data, language: String?) async throws -> String {
        receivedAudio = audioData
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

/// Grants the mic and hands back fixed audio when stopped.
private final class FixedAudioCapture: AudioCapturing, @unchecked Sendable {
    var currentAudioLevel: Float = 0
    var isRecording = false
    var isStarting = false
    let audio: Data
    init(audio: Data) { self.audio = audio }
    func micPermissionStatus() -> AVAudioSession.RecordPermission { .granted }
    func requestMicPermission() async -> Bool { true }
    func startCapture(
        onInterruption: @escaping @Sendable () -> Void,
        onMaximumDurationReached: @escaping @Sendable (Data?) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> AudioCaptureStartToken { AudioCaptureStartToken() }
    @MainActor func stopCapture() -> Data? { audio }
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

    @Test("a retry with copy off saves the text and leaves the clipboard alone")
    func retryWithoutCopy() async throws {
        let stt = SwitchableNoteSTT(error: nil)
        let (vm, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        let saved = try store.save(
            wav: Data(count: 44), surface: .note, notebookID: notebook.id, error: "e"
        )

        try await vm.retryPendingRecording(saved.id, copy: false)

        #expect(copied.isEmpty)
        #expect(store.all().isEmpty)
        #expect(service.entriesForNotebook(notebook.id).count == 1)
    }

    @Test("a permanent failure saved from a note stops auto-retry")
    func permanentFailureStartsStopped() async throws {
        let stt = SwitchableNoteSTT(error: .http(status: 415, body: ""))
        let (vm, _, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44))

        #expect(try #require(store.all().first).autoRetryStoppedAt != nil)
    }

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

    @Test("an open note receives the transcription and no new note is added")
    func transcriptGoesToOpenNote() async throws {
        let stt = SwitchableNoteSTT(error: nil)
        stt.transcript = "added by voice"
        let (vm, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        var received: String?
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44)) { received = $0 }

        #expect(received == "added by voice")
        #expect(vm.recordingState == .done)
        #expect(service.entriesForNotebook(notebook.id).isEmpty)
    }

    @Test("a failed recording for an open note keeps the audio and adds no text")
    func failedTranscriptForOpenNoteKeepsAudio() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }

        var received: String?
        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44)) { received = $0 }

        #expect(received == nil)
        #expect(store.all().count == 1)
        #expect(vm.lastFailureSavedForRetry)
    }

    @Test("an offline append saves M4A, and its retry hands the provider that M4A")
    func offlineAppendSavesM4A() async throws {
        let stt = SwitchableNoteSTT()
        let (vm, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }

        var received: String?
        await vm.recordAndStore(to: notebook.id, audioData: try pendingToneWAV()) { received = $0 }

        #expect(received == nil)
        let pending = try #require(store.all().first)
        #expect(store.audioURL(pending.id).pathExtension == "m4a")
        #expect(vm.lastFailureSavedForRetry)
        let stored = try store.audio(id: pending.id)
        #expect(AudioCaptureService.isM4A(stored))

        stt.error = nil
        try await vm.retryPendingRecording(pending.id)

        #expect(stt.receivedAudio == stored)
        #expect(store.all().isEmpty)
        #expect(service.entriesForNotebook(notebook.id).map(\.rawText) == ["note text"])
    }

    @Test("retrying a failed append adds to the original note, not a new one")
    func retryAppendsToOriginalNote() async throws {
        let stt = SwitchableNoteSTT()
        stt.transcript = "added later"
        let (vm, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var copied: [String] = []
        vm.copyText = { copied.append($0) }
        let note = try service.addEntry(to: notebook.id, rawText: "original", mode: "raw")

        await vm.recordAndStore(to: notebook.id, audioData: Data(count: 44), appendingTo: note.id) { _ in }
        let pending = try #require(store.all().first)
        #expect(pending.noteEntryID == note.id)

        stt.error = nil
        let text = try await vm.retryPendingRecording(pending.id)

        #expect(text == "added later")
        #expect(service.entriesForNotebook(notebook.id).map(\.rawText) == ["original added later"])
        #expect(copied == ["added later"])
        #expect(store.all().isEmpty)
    }

    @Test("a retried append goes after the processed text a note shows")
    func retryAppendsToShownText() async throws {
        let stt = SwitchableNoteSTT(error: nil)
        stt.transcript = "added"
        let (vm, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let note = try service.addEntry(
            to: notebook.id, rawText: "raw", processedText: "polished", mode: "llm"
        )
        let saved = try store.save(
            wav: Data(count: 44), surface: .note, notebookID: notebook.id, noteEntryID: note.id, error: "e"
        )

        try await vm.retryPendingRecording(saved.id)

        let entry = try #require(service.entriesForNotebook(notebook.id).first)
        #expect(entry.processedText == "polished added")
        #expect(entry.rawText == "raw")
    }

    @Test("a recording stopped while appending remembers its note")
    func stoppedAppendRemembersNote() async throws {
        let stt = SwitchableNoteSTT()
        let (_, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let vm = NoteViewModel(
            noteService: service, sttProvider: stt, llmProvider: nil,
            audioCapture: FixedAudioCapture(audio: Data(count: 44))
        )
        vm.pendingStore = store
        let note = try service.addEntry(to: notebook.id, rawText: "original", mode: "raw")

        vm.startRecording(to: notebook.id, appendingTo: note.id) { _ in }
        vm.stopRecording(to: notebook.id)
        while vm.recordingState == .processing { await Task.yield() }

        #expect(store.all().first?.noteEntryID == note.id)
    }

    @Test("an empty capture is queued as a 0:00 row without calling the server")
    func emptyCaptureIsQueued() async throws {
        let stt = SwitchableNoteSTT(error: nil)
        let (_, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let vm = NoteViewModel(
            noteService: service, sttProvider: stt, llmProvider: nil,
            audioCapture: FixedAudioCapture(audio: Data())
        )
        vm.pendingStore = store

        vm.startRecording(to: notebook.id)
        vm.stopRecording(to: notebook.id)
        while vm.recordingState == .processing { await Task.yield() }

        let pending = try #require(store.all().first)
        #expect(pending.notebookID == notebook.id)
        #expect(pending.durationSeconds == 0)
        #expect(pending.lastError == "No audio was captured (0 bytes).")
        #expect(pending.autoRetryStoppedAt != nil)
        #expect(vm.lastFailureSavedForRetry)
        #expect(stt.receivedAudio == nil)
        #expect(vm.recordingState == .error(message: "No audio was captured (0 bytes)."))
    }

    @Test("a 415 on real audio keeps playable audio in the queue")
    func unsupportedAudioKeepsTheClip() async throws {
        let stt = SwitchableNoteSTT(error: .http(status: 415, body: "{\"detail\":\"Unsupported audio\"}"))
        let (_, service, notebook, store) = try makeNotes(stt)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let vm = NoteViewModel(
            noteService: service, sttProvider: stt, llmProvider: nil,
            audioCapture: FixedAudioCapture(audio: try pendingToneWAV())
        )
        vm.pendingStore = store

        vm.startRecording(to: notebook.id)
        vm.stopRecording(to: notebook.id)
        while vm.recordingState == .processing { await Task.yield() }

        let pending = try #require(store.all().first)
        #expect(pending.durationSeconds > 0)
        #expect(pending.lastError.contains("415"))
        #expect(try !store.audio(id: pending.id).isEmpty)
        #expect(vm.lastFailureSavedForRetry)
    }

    @Test("a retried append whose note was deleted becomes a new note")
    func retryWithDeletedNote() async throws {
        let (vm, service, notebook, store) = try makeNotes(SwitchableNoteSTT(error: nil))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let note = try service.addEntry(to: notebook.id, rawText: "original", mode: "raw")
        let saved = try store.save(
            wav: Data(count: 44), surface: .note, notebookID: notebook.id, noteEntryID: note.id, error: "e"
        )
        try service.deleteEntry(note.id)

        try await vm.retryPendingRecording(saved.id)

        #expect(service.entriesForNotebook(notebook.id).map(\.rawText) == ["note text"])
        #expect(store.all().isEmpty)
    }

    @Test("a retried append that fails again leaves the note alone")
    func failedRetryLeavesNote() async throws {
        let (vm, service, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let note = try service.addEntry(to: notebook.id, rawText: "original", mode: "raw")
        let saved = try store.save(
            wav: Data(count: 44), surface: .note, notebookID: notebook.id, noteEntryID: note.id, error: "e"
        )

        await #expect(throws: STTError.networkUnavailable) {
            try await vm.retryPendingRecording(saved.id)
        }

        #expect(service.entriesForNotebook(notebook.id).map(\.rawText) == ["original"])
        #expect(store.recording(id: saved.id)?.noteEntryID == note.id)
    }

    @Test("a retry on a model that cannot read M4A fails and keeps the audio")
    func retryOnWAVOnlyProviderKeepsAudio() async throws {
        let (vm, service, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: pendingToneWAV(), surface: .note, notebookID: notebook.id, error: "e")
        let wavOnly = NoteViewModel(
            noteService: service, sttProvider: AppleSTT(), llmProvider: nil
        )
        wavOnly.pendingStore = store

        await #expect(throws: STTError.m4aUnsupported) {
            try await wavOnly.retryPendingRecording(saved.id)
        }
        #expect(store.recording(id: saved.id)?.attempts == 1)
        #expect(service.entriesForNotebook(notebook.id).isEmpty)
    }

    @Test("repeated offline appends keep every recording")
    func repeatedOfflineAppends() async throws {
        let (vm, _, notebook, store) = try makeNotes(SwitchableNoteSTT())
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let wav = try pendingToneWAV(seconds: 0.2)

        for _ in 0..<5 {
            await vm.recordAndStore(to: notebook.id, audioData: wav) { _ in }
        }

        #expect(store.pending(for: .notebook(notebook.id)).count == 5)
    }

    @Test("dictated text joins the note with one space")
    func appendingJoinsText() {
        #expect(NoteViewModel.appending("two", to: "one") == "one two")
        #expect(NoteViewModel.appending("two", to: "one\n") == "one\ntwo")
        #expect(NoteViewModel.appending("two", to: "") == "two")
        #expect(NoteViewModel.appending("", to: "one") == "one")
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
