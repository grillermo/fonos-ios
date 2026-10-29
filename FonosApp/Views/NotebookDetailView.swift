import SwiftUI

/// Entry list within a notebook.
struct NotebookDetailView: View {
    let notebook: NoteContainer
    let noteService: NoteService
    @ObservedObject var noteViewModel: NoteViewModel
    let autoRecordRequestID: UUID?

    @State private var entries: [NoteEntry] = []
    @State private var showRecordSheet = false
    @State private var handledAutoRecordRequestID: UUID?
    @State private var persistenceError: String?
    @State private var pendingRecordings: [PendingRecording] = []
    @State private var retryError: String?

    init(
        notebook: NoteContainer,
        noteService: NoteService,
        noteViewModel: NoteViewModel,
        autoRecordRequestID: UUID? = nil
    ) {
        self.notebook = notebook
        self.noteService = noteService
        self._noteViewModel = ObservedObject(wrappedValue: noteViewModel)
        self.autoRecordRequestID = autoRecordRequestID
    }

    var body: some View {
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

            // Floating action button
            Button {
                showRecordSheet = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color(hex: "#fbbf24"))
                        .frame(width: 60, height: 60)
                        .shadow(color: Color(hex: "#fbbf24").opacity(0.4), radius: 10, x: 0, y: 4)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(Color(hex: "#1a1917"))
                }
            }
            .padding(24)
        }
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.large)
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
                NavigationLink(destination: NotebookSettingsView(notebook: notebook, noteService: noteService)) {
                    Image(systemName: "gear")
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.7))
                }
            }
        }
        .onAppear { reloadEntries() }
        .onReceive(NotificationCenter.default.publisher(for: .pendingRecordingsChanged)) { _ in
            reloadEntries()
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
        .task(id: autoRecordRequestID) {
            guard let autoRecordRequestID,
                  handledAutoRecordRequestID != autoRecordRequestID else { return }
            handledAutoRecordRequestID = autoRecordRequestID
            showRecordSheet = true
        }
        .sheet(isPresented: $showRecordSheet, onDismiss: reloadEntries) {
            RecordNoteSheet(
                notebook: notebook,
                noteViewModel: noteViewModel,
                onDismiss: { showRecordSheet = false }
            )
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
                    title: String(localized: "Voice note"),
                    isRetrying: noteViewModel.retryingPendingIDs.contains(recording.id),
                    onRetry: { retry(recording.id) },
                    onDiscard: { noteViewModel.discardPendingRecording(recording.id) }
                )
                .listRowBackground(Color(hex: "#1a1917"))
                .listRowSeparator(.hidden)
            }
            ForEach(entries, id: \.id) { entry in
                EntryRow(entry: entry, showRawInline: notebook.showRawInline)
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
        entries = noteService.entriesForNotebook(notebook.id)
        pendingRecordings = noteViewModel.pendingStore.pending(for: .notebook(notebook.id))
    }

    private func retry(_ id: UUID) {
        Task {
            do {
                try await noteViewModel.retryPendingRecording(id)
            } catch is CancellationError {
            } catch {
                retryError = error.localizedDescription
            }
        }
    }

    /// Exports the notebook (entries in chronological order) and presents
    /// the system share sheet with the resulting file.
    private func shareExport(format: NoteExportFormat) {
        let chronological = noteService.entriesForNotebook(notebook.id).reversed()
        guard let url = try? noteService.exportFileURL(
            notebook: notebook,
            entries: Array(chronological),
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
