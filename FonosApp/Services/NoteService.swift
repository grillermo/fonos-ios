import Foundation
import SwiftData
import AppIntents

/// Errors thrown by NoteService.
enum NoteServiceError: LocalizedError, Equatable {
    case cannotDeleteQuickNote
    case notebookNotFound
    case entryNotFound
    case persistenceReadFailed(String)
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotDeleteQuickNote:
            "The Quick Note notebook cannot be deleted."
        case .notebookNotFound:
            "Notebook not found."
        case .entryNotFound:
            "Entry not found."
        case .persistenceReadFailed(let message):
            "The notes could not be loaded: \(message)"
        case .persistenceFailed(let message):
            "The note change could not be saved: \(message)"
        }
    }
}

/// Export formats supported by the notebook share sheet.
enum NoteExportFormat: String, CaseIterable, Sendable {
    case markdown = "md"
    case json = "json"
}

/// Service for creating and managing NoteContainer and NoteEntry objects.
@MainActor
final class NoteService {

    private let modelContainer: ModelContainer
    private let saveContext: (ModelContext) throws -> Void

    private static let quickNoteTitle = "Quick Note"
    static let quickNoteContainerType = "quick_note"

    static func isQuickNote(_ notebook: NoteContainer) -> Bool {
        notebook.containerType == quickNoteContainerType
    }

    init(
        modelContainer: ModelContainer,
        saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.modelContainer = modelContainer
        self.saveContext = saveContext
        Self.runBackfill(modelContainer: modelContainer)
        Self.runShowRawInlineDefault(modelContainer: modelContainer)
        syncCatalog()
    }

    // MARK: - One-shot: flip showRawInline default for existing notebooks

    private static let showRawInlineMigrationKey = "notebookConfig.showRawInline.defaultedTrue.v2"

    /// First launch after we changed the default for `showRawInline` from
    /// false → true: flip the existing rows so users can immediately see the
    /// raw STT transcript without hunting for the setting. Idempotent.
    static func runShowRawInlineDefault(modelContainer: ModelContainer, flagKey: String = showRawInlineMigrationKey) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: flagKey) { return }
        let context = modelContainer.mainContext
        guard let notebooks = try? context.fetch(FetchDescriptor<NoteContainer>()) else {
            return
        }
        var changed = false
        for nb in notebooks where nb.showRawInline == false {
            nb.showRawInline = true
            changed = true
        }
        if changed {
            do {
                try context.save()
            } catch {
                context.rollback()
                return
            }
        }
        defaults.set(true, forKey: flagKey)
    }

    // MARK: - Catalog sync

    /// Write the current notebook list to the shared App Group catalog so the
    /// FonosIntents code (AppShortcuts / DynamicOptionsProvider) sees an
    /// up-to-date list without booting the SwiftData stack. Also nudges
    /// Siri / Shortcuts.app to refresh suggested phrases. This is a derived
    /// cache: a catalog write failure must not undo an already-committed note.
    private func syncCatalog() {
        let entries = allNotebooks().map {
            SharedNotebookCatalog.Entry(id: $0.id.uuidString, title: $0.title)
        }
        try? SharedNotebookCatalog.write(entries)
        if #available(iOS 16.4, *) {
            FonosShortcuts.updateAppShortcutParameters()
        }
    }

    // MARK: - v1 → v2 Backfill

    private static let backfillFlagKey = "notebookConfig.migrated.v2"

    /// Runs once on first NoteService init for a given install. Translates
    /// `processingMode` + `customPrompt` into `systemPrompt`. Idempotent — guarded
    /// by a UserDefaults flag.
    static func runBackfill(modelContainer: ModelContainer, flagKey: String = backfillFlagKey) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: flagKey) { return }

        let context = modelContainer.mainContext
        guard let notebooks = try? context.fetch(FetchDescriptor<NoteContainer>()) else { return }

        var changed = false
        for nb in notebooks where nb.systemPrompt.isEmpty {
            let seed = backfillPrompt(processingMode: nb.processingMode, customPrompt: nb.customPrompt)
            if !seed.isEmpty {
                nb.systemPrompt = seed
                nb.updatedAt = Date()
                changed = true
            }
        }
        if changed {
            do {
                try context.save()
            } catch {
                context.rollback()
                return
            }
        }
        defaults.set(true, forKey: flagKey)
    }

    private static func backfillPrompt(processingMode: String, customPrompt: String?) -> String {
        switch processingMode {
        case "raw":
            return ""
        case "polish", "light_polish":
            return NotebookTemplate.polish.systemPromptSeed
        case "summarize":
            return NotebookTemplate.meetingNotes.systemPromptSeed
        default:
            return customPrompt ?? ""
        }
    }

    /// Convenience initializer with an in-memory container (for tests and export-only usage).
    convenience init() {
        let schema = Schema([NoteContainer.self, NoteEntry.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            self.init(modelContainer: container)
        } catch {
            fatalError("Failed to create the in-memory note container: \(error)")
        }
    }

    // MARK: - Quick Note

    /// Returns the Quick Note default notebook, creating it if it doesn't exist.
    /// Legacy title/duplicate-marker repairs are persisted atomically before a
    /// notebook is returned to the caller.
    func quickNoteNotebook() throws -> NoteContainer {
        let context = modelContainer.mainContext
        let marker = Self.quickNoteContainerType
        let markedDescriptor = FetchDescriptor<NoteContainer>(
            predicate: #Predicate { $0.containerType == marker },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let marked = try fetch(markedDescriptor, in: context)
        if let canonical = marked.first {
            // Synced/legacy stores may contain duplicate system markers. Keep a
            // deterministic canonical notebook and make the extras regular so
            // only one container receives untargeted Siri notes.
            for duplicate in marked.dropFirst() {
                duplicate.containerType = "notebook"
            }
            if marked.count > 1 {
                try persist(context)
                syncCatalog()
            }
            return canonical
        }

        // One-time compatibility for builds that identified Quick Note only by
        // its editable title. The oldest matching row becomes canonical; any
        // other same-title notebooks remain ordinary and deletable.
        let legacyTitle = Self.quickNoteTitle
        let legacyDescriptor = FetchDescriptor<NoteContainer>(
            predicate: #Predicate { $0.title == legacyTitle },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        if let legacy = try fetch(legacyDescriptor, in: context).first {
            legacy.containerType = marker
            legacy.updatedAt = Date()
            try persist(context)
            syncCatalog()
            return legacy
        }
        let notebook = NoteContainer(
            id: UUID(),
            title: Self.quickNoteTitle,
            containerType: marker,
            processingMode: "raw",
            createdAt: Date(),
            updatedAt: Date()
        )
        context.insert(notebook)
        try persist(context)
        syncCatalog()
        return notebook
    }

    // MARK: - Notebook CRUD

    /// Creates a new notebook with the given title and persists it.
    @discardableResult
    func createNotebook(
        title: String,
        containerType: String = "notebook",
        processingMode: String = "raw",
        sttModelOverride: String? = nil,
        llmModelOverride: String? = nil,
        customPrompt: String? = nil,
        systemPrompt: String = ""
    ) throws -> NoteContainer {
        let notebook = NoteContainer(
            id: UUID(),
            title: title,
            containerType: containerType,
            processingMode: processingMode,
            sttModelOverride: sttModelOverride,
            llmModelOverride: llmModelOverride,
            customPrompt: customPrompt,
            createdAt: Date(),
            updatedAt: Date(),
            systemPrompt: systemPrompt
        )
        let context = modelContainer.mainContext
        context.insert(notebook)
        try persist(context)
        syncCatalog()
        return notebook
    }

    /// Renames a notebook.
    func renameNotebook(_ id: UUID, to newTitle: String) throws {
        let context = modelContainer.mainContext
        let notebook = try requireNotebook(id, in: context)
        notebook.title = newTitle
        notebook.updatedAt = Date()
        try persist(context)
        syncCatalog()
    }

    /// Deletes a notebook. Throws if it's the Quick Note notebook.
    func deleteNotebook(_ id: UUID) throws {
        let context = modelContainer.mainContext
        let notebook = try requireNotebook(id, in: context)
        if Self.isQuickNote(notebook) {
            throw NoteServiceError.cannotDeleteQuickNote
        }
        let entriesDescriptor = FetchDescriptor<NoteEntry>(
            predicate: #Predicate { $0.containerId == id }
        )
        let entries = try fetch(entriesDescriptor, in: context)
        entries.forEach { context.delete($0) }
        context.delete(notebook)
        try persist(context)
        syncCatalog()
    }

    /// Fetches all notebooks sorted by updatedAt descending.
    func allNotebooks() -> [NoteContainer] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<NoteContainer>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Entry CRUD

    /// Adds a new entry to the notebook identified by `containerId`.
    @discardableResult
    func addEntry(
        to containerId: UUID,
        rawText: String,
        processedText: String? = nil,
        mode: String = "raw",
        durationMs: Double? = nil,
        language: String? = nil
    ) throws -> NoteEntry {
        let entry = NoteEntry(
            id: UUID(),
            createdAt: Date(),
            sourceType: "note",
            rawText: rawText,
            processedText: processedText,
            containerId: containerId,
            mode: mode,
            durationMs: durationMs,
            language: language
        )
        let context = modelContainer.mainContext
        context.insert(entry)
        try persist(context)
        return entry
    }

    /// Updates the rawText of an entry.
    func updateEntry(_ id: UUID, text: String) throws {
        let context = modelContainer.mainContext
        let entry = try requireEntry(id, in: context)
        entry.rawText = text
        try persist(context)
    }

    /// Deletes an entry.
    func deleteEntry(_ id: UUID) throws {
        try deleteEntries([id])
    }

    /// Deletes a swipe-selection in one save so a failure cannot leave a
    /// partially deleted list.
    func deleteEntries(_ ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let context = modelContainer.mainContext
        var seen = Set<UUID>()
        let entries = try ids.compactMap { id -> NoteEntry? in
            guard seen.insert(id).inserted else { return nil }
            return try requireEntry(id, in: context)
        }
        entries.forEach { context.delete($0) }
        try persist(context)
    }

    /// Returns entries for a notebook, sorted by createdAt descending (newest first).
    func entriesForNotebook(_ containerId: UUID) -> [NoteEntry] {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<NoteEntry>(
            predicate: #Predicate { $0.containerId == containerId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Returns the count of entries for a given notebook.
    func entryCount(for containerId: UUID) -> Int {
        entriesForNotebook(containerId).count
    }

    // MARK: - Lookup

    /// Returns the notebook with the given id, or nil if it doesn't exist.
    func notebook(id: UUID) -> NoteContainer? {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<NoteContainer>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

}

// MARK: - Export and persistence helpers

extension NoteService {

    // MARK: - Export

    /// ISO-8601 date formatter for export timestamps.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Exports a notebook and its entries as Markdown.
    func exportMarkdown(notebook: NoteContainer, entries: [NoteEntry]) -> String {
        var lines: [String] = []
        lines.append("# \(notebook.title)")
        lines.append("")

        if entries.isEmpty {
            lines.append("*No entries.*")
        } else {
            for (index, entry) in entries.enumerated() {
                let timestamp = Self.isoFormatter.string(from: entry.createdAt)
                lines.append("**\(timestamp)**")
                lines.append("")
                let text = entry.processedText ?? entry.rawText
                lines.append(text)
                if index < entries.count - 1 {
                    lines.append("")
                    lines.append("---")
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Exports a notebook and its entries as JSON.
    func exportJSON(notebook: NoteContainer, entries: [NoteEntry]) -> String {
        var root: [String: Any] = [
            "id": notebook.id.uuidString,
            "title": notebook.title,
            "container_type": notebook.containerType,
            "processing_mode": notebook.processingMode,
            "created_at": Self.isoFormatter.string(from: notebook.createdAt),
            "updated_at": Self.isoFormatter.string(from: notebook.updatedAt)
        ]

        let entryDicts: [[String: Any]] = entries.map { entry in
            var dict: [String: Any] = [
                "id": entry.id.uuidString,
                "created_at": Self.isoFormatter.string(from: entry.createdAt),
                "source_type": entry.sourceType,
                "raw_text": entry.rawText,
                "mode": entry.mode,
                "container_id": entry.containerId.uuidString
            ]
            if let processed = entry.processedText {
                dict["processed_text"] = processed
            }
            if let duration = entry.durationMs {
                dict["duration_ms"] = duration
            }
            if let lang = entry.language {
                dict["language"] = lang
            }
            return dict
        }
        root["entries"] = entryDicts

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }

    /// Writes an export to a temp file (named after the notebook) suitable
    /// for handing to a share sheet.
    func exportFileURL(notebook: NoteContainer,
                       entries: [NoteEntry],
                       format: NoteExportFormat) throws -> URL {
        let content: String
        switch format {
        case .markdown: content = exportMarkdown(notebook: notebook, entries: entries)
        case .json:     content = exportJSON(notebook: notebook, entries: entries)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.sanitizedFilename(notebook.title))
            .appendingPathExtension(format.rawValue)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Replaces path-hostile characters so the notebook title can be a filename.
    static func sanitizedFilename(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let joined = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let meaningful = joined.trimmingCharacters(
            in: CharacterSet(charactersIn: "-").union(.whitespacesAndNewlines)
        )
        return meaningful.isEmpty ? "Notebook" : joined
    }

    // MARK: - Per-notebook Configuration

    /// v2 config update — operates on the new fields.
    ///
    /// Each parameter is a double-optional so callers can distinguish
    /// "leave unchanged" (`nil`) from "clear to nil" (`.some(nil)`).
    func updateNotebookConfigV2(
        _ id: UUID,
        title: String? = nil,
        systemPrompt: String? = nil,
        sttLanguage: String?? = nil,
        outputLanguage: String?? = nil,
        sttModelOverride: String?? = nil,
        llmModelOverride: String?? = nil,
        showRawInline: Bool? = nil,
        siriPhrase: String?? = nil
    ) throws {
        let context = modelContainer.mainContext
        let nb = try requireNotebook(id, in: context)
        if let title { nb.title = title }
        if let systemPrompt { nb.systemPrompt = systemPrompt }
        if let sttLanguage { nb.sttLanguage = sttLanguage }
        if let outputLanguage { nb.outputLanguage = outputLanguage }
        if let sttModelOverride { nb.sttModelOverride = sttModelOverride }
        if let llmModelOverride { nb.llmModelOverride = llmModelOverride }
        if let showRawInline { nb.showRawInline = showRawInline }
        if let siriPhrase { nb.siriPhrase = siriPhrase }
        nb.updatedAt = Date()
        try persist(context)
        if title != nil { syncCatalog() }
    }

    // MARK: - Mutation support

    /// All user-triggered mutations pass through the injected saver. Rolling
    /// the live context back is essential: SwiftData otherwise keeps failed
    /// inserts, edits, and deletes visible to queries in the current process.
    private func persist(_ context: ModelContext) throws {
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            throw NoteServiceError.persistenceFailed(error.localizedDescription)
        }
    }

    private func fetch<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        in context: ModelContext
    ) throws -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw NoteServiceError.persistenceReadFailed(error.localizedDescription)
        }
    }

    private func requireNotebook(_ id: UUID, in context: ModelContext) throws -> NoteContainer {
        let descriptor = FetchDescriptor<NoteContainer>(
            predicate: #Predicate { $0.id == id }
        )
        guard let notebook = try fetch(descriptor, in: context).first else {
            throw NoteServiceError.notebookNotFound
        }
        return notebook
    }

    private func requireEntry(_ id: UUID, in context: ModelContext) throws -> NoteEntry {
        let descriptor = FetchDescriptor<NoteEntry>(
            predicate: #Predicate { $0.id == id }
        )
        guard let entry = try fetch(descriptor, in: context).first else {
            throw NoteServiceError.entryNotFound
        }
        return entry
    }
}
