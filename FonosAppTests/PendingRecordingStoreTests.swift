// Pending recordings: failed transcription audio is kept as <id>.wav +
// <id>.json until a retry succeeds or the user discards it.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingStoreTests

import Testing
import Foundation
@testable import FonosApp

private func makeTempStore() -> PendingRecordingStore {
    PendingRecordingStore(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
    )
}

/// 44-byte WAV header with a byte rate of 32 000, followed by one second of silence.
private func oneSecondWAV() -> Data {
    var data = Data(count: 44 + 32_000)
    var byteRate = UInt32(32_000).littleEndian
    withUnsafeBytes(of: &byteRate) { data.replaceSubrange(28..<32, with: $0) }
    return data
}

struct PendingRecordingStoreTests {

    @Test("save, list, read audio and discard round-trip")
    func roundTrip() throws {
        let store = makeTempStore()
        let wav = oneSecondWAV()
        let saved = try store.save(
            wav: wav, surface: .dictate, workflowID: "wf.dictation",
            error: "Network unavailable. Check your connection."
        )

        #expect(store.all() == [saved])
        #expect(try store.audio(id: saved.id) == wav)
        #expect(saved.durationSeconds == 1)
        #expect(saved.attempts == 0)

        store.discard(id: saved.id)
        #expect(store.all().isEmpty)
        #expect(store.recording(id: saved.id) == nil)
    }

    @Test("history scope lists dictate items; notebook scope lists that notebook's notes")
    func scopes() throws {
        let store = makeTempStore()
        let notebookA = UUID()
        let dictate = try store.save(wav: oneSecondWAV(), surface: .dictate, workflowID: "wf.dictation", error: "e")
        let noteA = try store.save(wav: oneSecondWAV(), surface: .note, notebookID: notebookA, error: "e")
        _ = try store.save(wav: oneSecondWAV(), surface: .note, notebookID: UUID(), error: "e")

        #expect(store.pending(for: .history) == [dictate])
        #expect(store.pending(for: .notebook(notebookA)) == [noteA])
    }

    @Test("all() is newest first")
    func ordering() throws {
        let store = makeTempStore()
        let old = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e", now: Date(timeIntervalSince1970: 1))
        let new = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e", now: Date(timeIntervalSince1970: 2))
        #expect(store.all().map(\.id) == [new.id, old.id])
    }

    @Test("recordAttempt increments attempts and replaces the error")
    func recordAttempt() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "first")
        store.recordAttempt(id: saved.id, error: "second")
        let updated = try #require(store.recording(id: saved.id))
        #expect(updated.attempts == 1)
        #expect(updated.lastError == "second")
    }

    @Test("a JSON whose WAV is missing is dropped")
    func orphanJSON() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e")
        try FileManager.default.removeItem(at: store.audioURL(saved.id))
        #expect(store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.metadataURL(saved.id).path))
    }

    @Test("a WAV without JSON is deleted only after an hour")
    func orphanWAV() throws {
        let store = makeTempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let id = UUID()
        try oneSecondWAV().write(to: store.audioURL(id))

        _ = store.all()
        #expect(FileManager.default.fileExists(atPath: store.audioURL(id).path))

        _ = store.all(now: Date().addingTimeInterval(2 * 3_600))
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(id).path))
    }

    @Test("shouldKeep rejects cancellation, empty audio and no-speech results")
    func shouldKeep() {
        let audio = Data(count: 44)
        #expect(PendingRecordingStore.shouldKeep(error: STTError.networkUnavailable, audio: audio))
        #expect(PendingRecordingStore.shouldKeep(error: STTError.authenticationFailed, audio: audio))
        #expect(!PendingRecordingStore.shouldKeep(error: CancellationError(), audio: audio))
        #expect(!PendingRecordingStore.shouldKeep(error: STTError.networkUnavailable, audio: Data()))
        #expect(!PendingRecordingStore.shouldKeep(error: STTError.noTranscript, audio: audio))
        #expect(!PendingRecordingStore.shouldKeep(
            error: VoiceWorkflowRuntimeError.emptyTranscript(widgetID: "stt"), audio: audio
        ))
    }

    /// Runs on the main actor so the store posts synchronously.
    @Test("changes post pendingRecordingsChanged")
    @MainActor
    func postsChange() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let store = makeTempStore()
        let posts = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .pendingRecordingsChanged, object: store, queue: nil
        ) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e")
        store.recordAttempt(id: saved.id, error: "e2")
        store.discard(id: saved.id)
        #expect(posts.value == 3)
    }
}
