import SwiftUI
import SwiftData

/// The Notes tab: one list of every note, newest first. Notebooks still exist
/// as storage (each carries its own pipeline settings and Siri target), but
/// the tab no longer shows them; new notes go to the Quick Note notebook.
struct NotesView: View {

    @StateObject private var noteViewModel: NoteViewModel
    private let noteService: NoteService
    private let recordingRequest: NoteRecordingDeepLinkRequest?

    @State private var entries: [NoteEntry] = []
    @State private var notebooksByID: [UUID: NoteContainer] = [:]
    @State private var pendingRecordings: [PendingRecording] = []
    /// The notebook the mic records into: Quick Note, or a deep link's target.
    @State private var recordingNotebook: NoteContainer?
    @State private var settingsNotebook: NoteContainer?
    @State private var editingEntry: NoteEntry?
    @State private var handledRecordingRequestID: UUID?
    @State private var routeError: String?
    @State private var persistenceError: String?
    @State private var retryError: String?

    // MARK: - Init

    /// Default init for use in ContentView — creates its own NoteService.
    init() {
        // Use an in-memory container for preview/default initialisation.
        // In production, ContentView passes a real container.
        let schema = Schema([NoteContainer.self, NoteEntry.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = (try? ModelContainer(for: schema, configurations: [config]))
            ?? { fatalError("Cannot create default ModelContainer") }()
        let service = NoteService(modelContainer: container)
        self._noteViewModel = StateObject(wrappedValue: NoteViewModel(noteService: service))
        self.noteService = service
        self.recordingRequest = nil
    }

    init(
        noteService: NoteService,
        noteViewModel: NoteViewModel,
        recordingRequest: NoteRecordingDeepLinkRequest? = nil
    ) {
        self.noteService = noteService
        self._noteViewModel = StateObject(wrappedValue: noteViewModel)
        self.recordingRequest = recordingRequest
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color(hex: "#1a1917")
                    .ignoresSafeArea()

                Group {
                    if entries.isEmpty && pendingRecordings.isEmpty {
                        emptyState
                    } else {
                        entriesList
                    }
                }

                MicActionButton { startRecording(into: nil) }
                    .padding(24)
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            shareExport(format: .markdown)
                        } label: {
                            Label("Export as Markdown", systemImage: "doc.text")
                        }
                        Button {
                            shareExport(format: .json)
                        } label: {
                            Label("Export as JSON", systemImage: "curlybraces")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(Color(hex: "#fafaf9").opacity(0.7))
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        do {
                            settingsNotebook = try noteService.quickNoteNotebook()
                        } catch {
                            routeError = error.localizedDescription
                        }
                    } label: {
                        Image(systemName: "gear")
                            .foregroundColor(Color(hex: "#fafaf9").opacity(0.7))
                    }
                }
            }
            .navigationDestination(item: $settingsNotebook) { notebook in
                NotebookSettingsView(notebook: notebook, noteService: noteService)
            }
            .onAppear { reloadEntries() }
            .onReceive(NotificationCenter.default.publisher(for: .pendingRecordingsChanged)) { _ in
                // A successful retry discards the item and changes a note.
                reloadEntries()
            }
            .sheet(item: $recordingNotebook, onDismiss: openRecordedNote) { notebook in
                RecordNoteSheet(
                    notebook: notebook,
                    noteViewModel: noteViewModel,
                    onDismiss: { recordingNotebook = nil }
                )
            }
            .sheet(item: $editingEntry, onDismiss: reloadEntries) { entry in
                EditNoteSheet(entry: entry, notebook: notebook(for: entry), noteViewModel: noteViewModel) { text in
                    try noteService.updateEntry(entry.id, text: text)
                }
            }
            .alert(
                "Notes Unavailable",
                isPresented: Binding(
                    get: { routeError != nil },
                    set: { if !$0 { routeError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { routeError = nil }
            } message: {
                Text(routeError ?? "")
            }
            .alert(
                "Entry Could Not Be Deleted",
                isPresented: Binding(
                    get: { persistenceError != nil },
                    set: { if !$0 { persistenceError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { persistenceError = nil }
            } message: {
                Text(persistenceError ?? "")
            }
            .alert(
                "Retry Failed",
                isPresented: Binding(
                    get: { retryError != nil },
                    set: { if !$0 { retryError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { retryError = nil }
            } message: {
                Text(retryError ?? "")
            }
        }
        .preferredColorScheme(.dark)
        // Not `.task`: it would rerun each time the list reappears.
        .onChange(of: recordingRequest?.id, initial: true) {
            guard let recordingRequest,
                  handledRecordingRequestID != recordingRequest.id else { return }
            handledRecordingRequestID = recordingRequest.id
            openAndRecord(request: recordingRequest)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.circle")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(Color(hex: "#fafaf9").opacity(0.2))
            Text("No entries yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color(hex: "#fafaf9").opacity(0.4))
            Text("Tap the mic button to record your first note")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#fafaf9").opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entries List

    private var entriesList: some View {
        List {
            ForEach(pendingRecordings) { recording in
                PendingRecordingRow(
                    recording: recording,
                    title: recording.noteEntryID == nil
                        ? String(localized: "Voice note")
                        : String(localized: "Addition to a note"),
                    isRetrying: noteViewModel.retryingPendingIDs.contains(recording.id),
                    onRetry: { retry(recording.id) },
                    onDiscard: { noteViewModel.discardPendingRecording(recording.id) }
                )
                .listRowBackground(Color(hex: "#1a1917"))
                .listRowSeparator(.hidden)
            }
            ForEach(entries, id: \.id) { entry in
                Button {
                    editingEntry = entry
                } label: {
                    EntryRow(
                        entry: entry,
                        showRawInline: notebooksByID[entry.containerId]?.showRawInline ?? true
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color(hex: "#1a1917"))
                .listRowSeparatorTint(Color(hex: "#fafaf9").opacity(0.08))
            }
            .onDelete { indexSet in
                let ids = indexSet.map { entries[$0].id }
                do {
                    try noteService.deleteEntries(ids)
                    reloadEntries()
                } catch {
                    persistenceError = error.localizedDescription
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Helpers

    private func reloadEntries() {
        entries = noteService.allEntries()
        notebooksByID = Dictionary(
            noteService.allNotebooks().map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        pendingRecordings = noteViewModel.pendingStore.pending(for: .notes)
    }

    /// After a recording sheet closes, opens the note it created for editing
    /// (cursor at the end) instead of leaving the user on the list.
    private func openRecordedNote() {
        reloadEntries()
        guard noteViewModel.recordingState == .done,
              let id = noteViewModel.lastCreatedEntryID,
              let entry = entries.first(where: { $0.id == id }) else { return }
        editingEntry = entry
    }

    /// The notebook an entry was recorded into, whose settings an edit's
    /// dictated additions use. Falls back to Quick Note for orphaned entries.
    private func notebook(for entry: NoteEntry) -> NoteContainer {
        if let notebook = notebooksByID[entry.containerId] ?? noteService.notebook(id: entry.containerId) {
            return notebook
        }
        return (try? noteService.quickNoteNotebook()) ?? NoteContainer(title: "Notes")
    }

    /// Opens the recorder on `notebook`, or on Quick Note when nil.
    private func startRecording(into notebook: NoteContainer?) {
        if let notebook {
            recordingNotebook = notebook
            return
        }
        do {
            recordingNotebook = try noteService.quickNoteNotebook()
        } catch {
            routeError = error.localizedDescription
        }
    }

    private func retry(_ id: UUID) {
        Task {
            do {
                try await noteViewModel.retryPendingRecording(id)
            } catch is CancellationError {
                // Cancelled, not failed: nothing to report.
            } catch {
                retryError = error.localizedDescription
            }
            reloadEntries()
        }
    }

    /// Exports every note (chronological order) and presents the share sheet.
    private func shareExport(format: NoteExportFormat) {
        let chronological = Array(noteService.allEntries().reversed())
        // Unsaved stand-in, only so the export carries the "Notes" title.
        let allNotes = NoteContainer(title: String(localized: "Notes"), containerType: "all_notes")
        guard let url = try? noteService.exportFileURL(
            notebook: allNotes,
            entries: chronological,
            format: format
        ) else { return }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        presenter.present(activityVC, animated: true)
    }

    /// Resolves a deep link's notebook before recording. An invalid explicit
    /// target (e.g. a Siri shortcut set up for an old notebook) is reported
    /// instead of silently recording elsewhere; an omitted one means Quick Note.
    private func openAndRecord(request: NoteRecordingDeepLinkRequest) {
        guard !noteViewModel.isCapturePendingOrActive else {
            routeError = "A voice note is already starting or recording. Finish it before starting another."
            return
        }
        switch noteViewModel.recordingState {
        case .recording, .processing:
            routeError = "A voice note is already in progress. Finish it before starting another."
            return
        case .idle, .done, .error:
            break
        }

        if let value = request.notebookID {
            guard let id = UUID(uuidString: value),
                  let requested = noteService.notebook(id: id) else {
                routeError = "The requested notebook could not be found. No recording was started."
                return
            }
            startRecording(into: requested)
        } else {
            startRecording(into: nil)
        }
    }
}

// MARK: - EntryRow

private struct EntryRow: View {
    let entry: NoteEntry
    let showRawInline: Bool

    private var hasDistinctRaw: Bool {
        guard let processed = entry.processedText else { return false }
        return processed != entry.rawText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.createdAt, style: .time)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.4))
                Spacer()
                modeBadge
            }

            Text(entry.processedText ?? entry.rawText)
                .font(.system(size: 15))
                .foregroundColor(Color(hex: "#fafaf9"))
                .lineLimit(4)
                .multilineTextAlignment(.leading)

            if showRawInline && hasDistinctRaw {
                Text(entry.rawText)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.35))
                    .lineLimit(4)
            }
        }
        .padding(.vertical, 8)
        .contextMenu {
            if hasDistinctRaw {
                Button {
                    UIPasteboard.general.string = entry.rawText
                } label: {
                    Label("Copy raw transcript", systemImage: "doc.on.doc")
                }
            }
            Button {
                UIPasteboard.general.string = entry.processedText ?? entry.rawText
            } label: {
                Label("Copy text", systemImage: "doc.on.doc.fill")
            }
        }
    }

    private var modeBadge: some View {
        Text(entry.mode)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Color(hex: "#fbbf24").opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(hex: "#fbbf24").opacity(0.1)))
    }
}

#Preview {
    NotesView()
}
