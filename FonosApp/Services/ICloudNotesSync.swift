import Foundation
import SwiftData
import os

private let syncLog = Logger(subsystem: "com.fonos.ios", category: "ICloudNotesSync")

/// `MirrorFileSystem` that goes through `NSFileCoordinator`, as Apple requires
/// for files inside an iCloud ubiquity container.
struct CoordinatedMirrorFileSystem: MirrorFileSystem {
    private let plain = PlainMirrorFileSystem()

    func exists(_ url: URL) -> Bool {
        var found = false
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            found = plain.exists(url)
        }
        if coordinationError != nil { return false }
        return found
    }

    func contents(of url: URL) -> Data? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            data = plain.contents(of: url)
        }
        return data
    }

    func write(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { url in
            do { try plain.write(data, to: url) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    func remove(_ url: URL) throws {
        var coordinationError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do { try plain.remove(url) } catch { removeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let removeError { throw removeError }
    }
}

/// Keeps iCloud Drive → Fonos in step with the notebooks, one `.md` per
/// notebook. One-way and always on: when iCloud Drive is unavailable it logs
/// once and does nothing. Failures never reach the UI or note saving.
@MainActor
final class ICloudNotesSync {
    nonisolated static let containerID = "iCloud.me.chiq.fonos"

    private let modelContainer: ModelContainer
    private let debounce: Duration
    private lazy var noteService = NoteService(modelContainer: modelContainer)

    private var pending: Task<Void, Never>?
    private var saveObserver: NSObjectProtocol?
    private var isRunning = false
    private var rerunRequested = false
    private var documentsURL: URL?
    private var loggedUnavailable = false

    init(modelContainer: ModelContainer, debounce: Duration = .seconds(2)) {
        self.modelContainer = modelContainer
        self.debounce = debounce
    }

    /// Observes SwiftData saves and runs a first sync.
    func start() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        schedule()
    }

    /// Runs a sync `debounce` from now, replacing any pending one.
    func schedule() {
        pending?.cancel()
        pending = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    private func run() async {
        guard !isRunning else {
            rerunRequested = true
            return
        }
        isRunning = true
        repeat {
            rerunRequested = false
            await mirrorOnce()
        } while rerunRequested
        isRunning = false
    }

    private func mirrorOnce() async {
        guard let root = await resolveDocumentsURL() else {
            if !loggedUnavailable {
                syncLog.info("iCloud Drive unavailable; notes are not mirrored")
                loggedUnavailable = true
            }
            return
        }
        let notebooks = snapshot()
        let result = await Task.detached(priority: .utility) {
            NotesMirror(root: root, fileSystem: CoordinatedMirrorFileSystem()).sync(notebooks)
        }.value
        syncLog.info("""
            Notes mirrored: \(result.written) written, \(result.deleted) deleted, \
            \(result.unchanged) unchanged, \(result.failed) failed
            """)
    }

    /// `url(forUbiquityContainerIdentifier:)` can block, so it runs off-main.
    private func resolveDocumentsURL() async -> URL? {
        if let documentsURL { return documentsURL }
        let url = await Task.detached(priority: .utility) {
            FileManager.default
                .url(forUbiquityContainerIdentifier: ICloudNotesSync.containerID)?
                .appendingPathComponent("Documents", isDirectory: true)
        }.value
        documentsURL = url
        return url
    }

    private func snapshot() -> [NotesMirror.Notebook] {
        noteService.allNotebooks().map { notebook in
            NotesMirror.Notebook(
                id: notebook.id,
                baseName: NoteService.sanitizedFilename(notebook.title),
                createdAt: notebook.createdAt,
                markdown: noteService.exportMarkdown(
                    notebook: notebook,
                    entries: noteService.entriesForNotebook(notebook.id)
                )
            )
        }
    }
}
