// Pending recordings: failed transcription audio is kept as <id>.m4a (notes)
// or <id>.wav (dictation) + <id>.json until a retry succeeds or the user
// discards it.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/PendingRecordingStoreTests

import Testing
import Foundation
import AVFoundation
@testable import FonosApp

/// 44-byte WAV header with a byte rate of 32 000, followed by one second of silence.
private func oneSecondWAV() -> Data {
    var data = Data(count: 44 + 32_000)
    var byteRate = UInt32(32_000).littleEndian
    withUnsafeBytes(of: &byteRate) { data.replaceSubrange(28..<32, with: $0) }
    return data
}

/// A real capture-format WAV (16 kHz mono) that AVAudioFile can encode.
func pendingToneWAV(seconds: Double = 2) throws -> Data {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false
    ))
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.int16ChannelData)
    for frame in 0..<Int(frames) {
        samples[0][frame] = Int16(sin(Double(frame) / 16_000 * 440 * 2 * .pi) * 12_000)
    }
    return try AudioCaptureService.encodeToWAV(buffer: buffer)
}

final class PendingRecordingStoreTests {
    private var stores: [PendingRecordingStore] = []

    private func makeTempStore() -> PendingRecordingStore {
        let store = PendingRecordingStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true)
        )
        stores.append(store)
        return store
    }

    deinit {
        for store in stores { try? FileManager.default.removeItem(at: store.directory) }
    }

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

    @Test("metadata from earlier builds decodes without autoRetryStoppedAt")
    func decodesOldMetadata() throws {
        let json = """
        {"id":"\(UUID().uuidString)","surface":"note","createdAt":0,
         "lastError":"e","attempts":1,"durationSeconds":2}
        """
        let recording = try JSONDecoder().decode(PendingRecording.self, from: Data(json.utf8))
        #expect(recording.autoRetryStoppedAt == nil)
    }

    @Test("a permanent failure stops auto-retry and a temporary one restores it")
    func attemptSetsAndClearsStop() throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e")
        #expect(saved.autoRetryStoppedAt == nil)

        store.recordAttempt(id: saved.id, failure: STTError.http(status: 415, body: ""))
        #expect(store.recording(id: saved.id)?.autoRetryStoppedAt != nil)

        store.recordAttempt(id: saved.id, failure: STTError.timeout)
        #expect(store.recording(id: saved.id)?.autoRetryStoppedAt == nil)
        #expect(store.recording(id: saved.id)?.attempts == 2)
    }

    @Test("a recording first saved with a permanent failure starts stopped")
    func saveWithPermanentFailure() throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let saved = try store.save(
            wav: oneSecondWAV(), surface: .dictate, error: "e", autoRetryStopped: true
        )
        #expect(store.recording(id: saved.id)?.autoRetryStoppedAt != nil)
    }

    @Test("a failed keyboard run keeps its audio as a dictation")
    func keyboardFailureKeepsAudio() throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        BackgroundRecordingService.keepFailedRecording(
            STTError.networkUnavailable,
            wavData: oneSecondWAV(),
            workflowID: "wf.keyboard",
            textSaved: false,
            store: store
        )

        let pending = try #require(store.all().first)
        #expect(pending.surface == .dictate)
        #expect(pending.workflowID == "wf.keyboard")
    }

    @Test("a keyboard 415 keeps its audio and stops auto-retry")
    func keyboardUnsupportedAudioKeepsAudio() throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        BackgroundRecordingService.keepFailedRecording(
            STTError.http(status: 415, body: "x"),
            wavData: oneSecondWAV(),
            workflowID: "wf.keyboard",
            textSaved: false,
            store: store
        )

        let pending = try #require(store.all().first)
        #expect(pending.lastError.contains("415"))
        #expect(pending.autoRetryStoppedAt != nil)
        #expect(try store.audio(id: pending.id) == oneSecondWAV())
    }

    @Test("a keyboard capture with no samples is queued as a 0:00 row")
    func keyboardEmptyCaptureIsQueued() throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        BackgroundRecordingService.keepUnsentCapture(
            wavData: Data(count: 44), workflowID: "wf.keyboard", store: store
        )

        let pending = try #require(store.all().first)
        #expect(pending.surface == .dictate)
        #expect(pending.workflowID == "wf.keyboard")
        #expect(pending.durationSeconds == 0)
        #expect(pending.lastError == PendingRecordingStore.noAudioMessage)
        #expect(pending.autoRetryStoppedAt != nil)
    }

    @Test("a keyboard capture with some audio keeps it")
    func keyboardShortCaptureKeepsAudio() throws {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        BackgroundRecordingService.keepUnsentCapture(
            wavData: oneSecondWAV(), workflowID: "wf.keyboard", store: store
        )

        let pending = try #require(store.all().first)
        #expect(pending.durationSeconds > 0)
        #expect(pending.lastError.hasPrefix("Too short to send"))
        #expect(try store.audio(id: pending.id) == oneSecondWAV())
    }

    @Test("a keyboard run keeps nothing when cancelled or already in History")
    func keyboardFailureKeepsNothing() {
        let store = makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        BackgroundRecordingService.keepFailedRecording(
            CancellationError(), wavData: oneSecondWAV(), workflowID: "w",
            textSaved: false, store: store
        )
        BackgroundRecordingService.keepFailedRecording(
            STTError.timeout, wavData: oneSecondWAV(), workflowID: "w",
            textSaved: true, store: store
        )

        #expect(store.all().isEmpty)
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

    @Test("a JSON whose audio is missing is dropped")
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

    @Test("note audio is stored as M4A and read back unchanged")
    func noteAudioIsM4A() throws {
        let store = makeTempStore()
        let wav = try pendingToneWAV()
        let saved = try store.save(wav: wav, surface: .note, notebookID: UUID(), error: "e")

        let url = store.audioURL(saved.id)
        #expect(url.pathExtension == "m4a")
        let stored = try Data(contentsOf: url)
        #expect(AudioCaptureService.isM4A(stored))
        #expect(stored.count < wav.count)
        #expect(saved.durationSeconds == 2)
        #expect(try store.audio(id: saved.id) == stored)
    }

    @Test("dictation audio stays WAV")
    func dictationAudioIsWAV() throws {
        let store = makeTempStore()
        let wav = try pendingToneWAV()
        let saved = try store.save(wav: wav, surface: .dictate, workflowID: "wf.dictation", error: "e")

        #expect(store.audioURL(saved.id).pathExtension == "wav")
        #expect(try store.audio(id: saved.id) == wav)
    }

    @Test("audio that cannot be encoded is still kept, as WAV")
    func encodeFailureKeepsWAV() throws {
        let store = makeTempStore()
        let unencodable = Data(count: 100)
        let saved = try store.save(wav: unencodable, surface: .note, notebookID: UUID(), error: "e")

        #expect(store.audioURL(saved.id).pathExtension == "wav")
        #expect(try store.audio(id: saved.id) == unencodable)
    }

    @Test("a note recording saved as WAV by an earlier build still works")
    func legacyNoteWAV() throws {
        let store = makeTempStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let legacy = PendingRecording(
            id: UUID(), surface: .note, workflowID: nil, notebookID: UUID(),
            createdAt: Date(), lastError: "e", attempts: 0, durationSeconds: 1
        )
        let wav = try pendingToneWAV(seconds: 1)
        try wav.write(to: store.directory.appendingPathComponent("\(legacy.id.uuidString).wav"))
        try JSONEncoder().encode(legacy).write(to: store.metadataURL(legacy.id))

        #expect(store.all() == [legacy])
        #expect(try store.audio(id: legacy.id) == wav)

        store.discard(id: legacy.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test("the note being appended to survives a save, and old items have none")
    func noteEntryIDRoundTrip() throws {
        let store = makeTempStore()
        let note = UUID()
        let saved = try store.save(
            wav: oneSecondWAV(), surface: .note, notebookID: UUID(), noteEntryID: note, error: "e"
        )
        #expect(store.recording(id: saved.id)?.noteEntryID == note)

        store.recordAttempt(id: saved.id, error: "again")
        #expect(store.recording(id: saved.id)?.noteEntryID == note)

        let old = Data(#"{"id":"\#(UUID().uuidString)","surface":"note","createdAt":0,"lastError":"e","attempts":0,"durationSeconds":1}"#.utf8)
        #expect(try JSONDecoder().decode(PendingRecording.self, from: old).noteEntryID == nil)
    }

    @Test("discard removes the M4A and its JSON")
    func discardRemovesM4A() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: pendingToneWAV(), surface: .note, notebookID: UUID(), error: "e")
        store.discard(id: saved.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).isEmpty)
    }

    @Test("an M4A without JSON is deleted only after an hour")
    func orphanM4A() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: pendingToneWAV(), surface: .note, notebookID: UUID(), error: "e")
        let url = store.audioURL(saved.id)
        try FileManager.default.removeItem(at: store.metadataURL(saved.id))

        _ = store.all()
        #expect(FileManager.default.fileExists(atPath: url.path))

        _ = store.all(now: Date().addingTimeInterval(2 * 3_600))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("any number of note recordings is kept")
    func noLimit() throws {
        let store = makeTempStore()
        let notebook = UUID()
        let wav = try pendingToneWAV(seconds: 0.1)
        let saved = try (0..<150).map { _ in
            try store.save(wav: wav, surface: .note, notebookID: notebook, error: "e")
        }
        #expect(Set(store.pending(for: .notebook(notebook)).map(\.id)) == Set(saved.map(\.id)))
    }

    @Test("a corrupt JSON is skipped but its files are kept")
    func corruptJSON() throws {
        let store = makeTempStore()
        let saved = try store.save(wav: oneSecondWAV(), surface: .dictate, error: "e")
        try Data("not json".utf8).write(to: store.metadataURL(saved.id))

        #expect(store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.metadataURL(saved.id).path))
        #expect(FileManager.default.fileExists(atPath: store.audioURL(saved.id).path))
    }

    @Test("audio(id:) throws notFound only when the file is missing")
    func audioNotFound() {
        let store = makeTempStore()
        #expect(throws: PendingRecordingError.notFound) { try store.audio(id: UUID()) }
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
