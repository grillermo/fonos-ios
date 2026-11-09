import Foundation
import os.log

private let pendingLog = Logger(subsystem: "com.fonos.ios", category: "PendingRecordingStore")

extension Notification.Name {
    static let pendingRecordingsChanged = Notification.Name("com.fonos.ios.pendingRecordingsChanged")
}

/// Keeps failed recordings as audio + `<id>.json` in the App Group so they can
/// be retried later, for as long as it takes and with no limit on how many.
/// Notes are stored as `<id>.m4a`; dictation, notes from earlier builds, and
/// note audio that could not be encoded are `<id>.wav`. The audio is written
/// before its JSON, so a JSON never points at missing audio; `all()` cleans up
/// whatever a crash left.
final class PendingRecordingStore: @unchecked Sendable {
    static let shared = PendingRecordingStore(directory: defaultDirectory())

    /// Audio this old with no JSON was abandoned mid-save.
    private static let orphanAudioAge: TimeInterval = 3_600

    /// What a capture with no samples reports, on screen and in its 0:00 row.
    static let noAudioMessage = "No audio was captured (0 bytes)."

    let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardIPC.appGroupID
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PendingRecordings", isDirectory: true)
    }

    /// Cancellation, empty audio and "no speech" leave nothing worth retrying.
    static func shouldKeep(error: Error, audio: Data) -> Bool {
        guard !audio.isEmpty, !(error is CancellationError) else { return false }
        if let sttError = error as? STTError, sttError == .noTranscript { return false }
        if let runtimeError = error as? VoiceWorkflowRuntimeError,
           case .emptyTranscript = runtimeError { return false }
        return true
    }

    /// Seconds of audio in a PCM WAV, read from the header's byte rate.
    static func duration(ofWAV data: Data) -> TimeInterval {
        guard data.count > 44 else { return 0 }
        let byteRate = data.subdata(in: 28..<32).withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
        guard byteRate > 0 else { return 0 }
        return Double(data.count - 44) / Double(byteRate)
    }

    /// Where a recording's audio is. An item with no audio resolves to M4A.
    func audioURL(_ id: UUID) -> URL {
        let wav = audioURL(id, fileExtension: "wav")
        return fileManager.fileExists(atPath: wav.path) ? wav : audioURL(id, fileExtension: "m4a")
    }

    private func audioURL(_ id: UUID, fileExtension: String) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(fileExtension)")
    }

    func metadataURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    @discardableResult
    func save(
        wav: Data,
        surface: PendingRecording.Surface,
        workflowID: String? = nil,
        notebookID: UUID? = nil,
        noteEntryID: UUID? = nil,
        error: String,
        autoRetryStopped: Bool = false,
        now: Date = Date()
    ) throws -> PendingRecording {
        let recording = PendingRecording(
            id: UUID(),
            surface: surface,
            workflowID: workflowID,
            notebookID: notebookID,
            createdAt: now,
            lastError: error,
            attempts: 0,
            durationSeconds: Self.duration(ofWAV: wav),
            noteEntryID: noteEntryID,
            autoRetryStoppedAt: autoRetryStopped ? now : nil
        )
        let m4a = surface == .note ? encodedForStorage(wav) : nil
        let audioFile = audioURL(recording.id, fileExtension: m4a == nil ? "wav" : "m4a")
        try lock.withLock {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try (m4a ?? wav).write(to: audioFile, options: .atomic)
            do {
                try writeMetadata(recording)
            } catch {
                try? fileManager.removeItem(at: audioFile)
                throw error
            }
        }
        pendingLog.info("Kept failed recording \(recording.id.uuidString.prefix(8), privacy: .public) for retry")
        postChange()
        return recording
    }

    /// Every pending recording, newest first. Drops JSONs whose audio is gone
    /// and audio left without JSON for over an hour.
    func all(now: Date = Date()) -> [PendingRecording] {
        lock.withLock {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                return []
            }
            var recordings: [PendingRecording] = []
            for name in names where name.hasSuffix(".json") {
                let url = directory.appendingPathComponent(name)
                guard let recording = readMetadata(at: url) else {
                    pendingLog.error("Skipping unreadable pending metadata \(name, privacy: .public)")
                    continue
                }
                guard fileManager.fileExists(atPath: audioURL(recording.id).path) else {
                    try? fileManager.removeItem(at: url)
                    continue
                }
                recordings.append(recording)
            }
            let known = Set(recordings.map(\.id.uuidString))
            for name in names {
                let url = directory.appendingPathComponent(name)
                guard ["wav", "m4a"].contains(url.pathExtension),
                      !known.contains(url.deletingPathExtension().lastPathComponent) else { continue }
                let created = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
                if now.timeIntervalSince(created ?? now) > Self.orphanAudioAge {
                    try? fileManager.removeItem(at: url)
                }
            }
            return recordings.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func pending(for scope: PendingRecording.Scope) -> [PendingRecording] {
        all().filter { recording in
            switch scope {
            case .history:
                recording.surface == .dictate
            case .notes:
                recording.surface == .note
            case .notebook(let id):
                recording.surface == .note && recording.notebookID == id
            }
        }
    }

    func recording(id: UUID) -> PendingRecording? {
        lock.withLock {
            guard fileManager.fileExists(atPath: audioURL(id).path) else { return nil }
            return readMetadata(at: metadataURL(id))
        }
    }

    /// The recording's stored bytes, M4A or WAV.
    func audio(id: UUID) throws -> Data {
        try lock.withLock {
            do {
                return try Data(contentsOf: audioURL(id))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                throw PendingRecordingError.notFound
            }
        }
    }

    func discard(id: UUID) {
        lock.withLock {
            try? fileManager.removeItem(at: metadataURL(id))
            try? fileManager.removeItem(at: audioURL(id, fileExtension: "m4a"))
            try? fileManager.removeItem(at: audioURL(id, fileExtension: "wav"))
        }
        postChange()
    }

    func recordAttempt(id: UUID, error: String, permanent: Bool = false, now: Date = Date()) {
        let updated: Bool = lock.withLock {
            guard var recording = readMetadata(at: metadataURL(id)) else { return false }
            recording.attempts += 1
            recording.lastError = error
            recording.autoRetryStoppedAt = permanent ? now : nil
            do {
                try writeMetadata(recording)
                return true
            } catch {
                pendingLog.error("Could not record retry attempt: \(error.localizedDescription)")
                return false
            }
        }
        if updated { postChange() }
    }

    /// Records a failed retry, stopping auto-retry when the failure is permanent.
    func recordAttempt(id: UUID, failure: any Error) {
        recordAttempt(
            id: id,
            error: failure.localizedDescription,
            permanent: PendingRecordingFailure.classify(failure) == .permanent
        )
    }

    /// nil keeps the WAV: a failed encode must not lose the recording.
    private func encodedForStorage(_ wav: Data) -> Data? {
        do {
            return try AudioCaptureService.encodeToM4A(wavData: wav)
        } catch {
            pendingLog.error("Keeping WAV, M4A encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private (call with the lock held)

    private func readMetadata(at url: URL) -> PendingRecording? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingRecording.self, from: data)
    }

    private func writeMetadata(_ recording: PendingRecording) throws {
        let data = try JSONEncoder().encode(recording)
        try data.write(to: metadataURL(recording.id), options: .atomic)
    }

    private func postChange() {
        let post = { NotificationCenter.default.post(name: .pendingRecordingsChanged, object: self) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
