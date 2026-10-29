import Foundation
import os.log

private let pendingLog = Logger(subsystem: "com.fonos.ios", category: "PendingRecordingStore")

extension Notification.Name {
    static let pendingRecordingsChanged = Notification.Name("com.fonos.ios.pendingRecordingsChanged")
}

/// Keeps failed recordings as `<id>.wav` + `<id>.json` in the App Group so
/// they can be retried later. The WAV is written before its JSON, so a JSON
/// never points at missing audio; `all()` cleans up whatever a crash left.
final class PendingRecordingStore: @unchecked Sendable {
    static let shared = PendingRecordingStore(directory: defaultDirectory())

    /// A WAV this old with no JSON was abandoned mid-save.
    private static let orphanAudioAge: TimeInterval = 3_600

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

    func audioURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
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
        error: String,
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
            durationSeconds: Self.duration(ofWAV: wav)
        )
        try lock.withLock {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try wav.write(to: audioURL(recording.id), options: .atomic)
            do {
                try writeMetadata(recording)
            } catch {
                try? fileManager.removeItem(at: audioURL(recording.id))
                throw error
            }
        }
        pendingLog.info("Kept failed recording \(recording.id.uuidString.prefix(8), privacy: .public) for retry")
        postChange()
        return recording
    }

    /// Every pending recording, newest first. Drops JSONs whose WAV is gone
    /// and WAVs left without JSON for over an hour.
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
            let known = Set(recordings.map { "\($0.id.uuidString).wav" })
            for name in names where name.hasSuffix(".wav") && !known.contains(name) {
                let url = directory.appendingPathComponent(name)
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
            try? fileManager.removeItem(at: audioURL(id))
        }
        postChange()
    }

    func recordAttempt(id: UUID, error: String) {
        let updated: Bool = lock.withLock {
            guard var recording = readMetadata(at: metadataURL(id)) else { return false }
            recording.attempts += 1
            recording.lastError = error
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
