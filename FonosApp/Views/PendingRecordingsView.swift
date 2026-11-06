import SwiftUI

/// Every recording waiting for transcription, from Dictate, the keyboard and
/// Notes. A row's Retry copies the text; Retry All doesn't.
struct PendingRecordingsView: View {
    @ObservedObject var dictationViewModel: DictationViewModel
    @ObservedObject var noteViewModel: NoteViewModel
    @ObservedObject var autoRetrier: PendingRecordingAutoRetrier
    let noteService: NoteService

    @State private var recordings: [PendingRecording] = []
    @State private var retryError: String?

    private var store: PendingRecordingStore { dictationViewModel.pendingStore }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#1a1917")
                    .ignoresSafeArea()

                if recordings.isEmpty {
                    ContentUnavailableView(
                        "Nothing pending",
                        systemImage: "checkmark.circle",
                        description: Text("Recordings that couldn't be transcribed wait here.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Pending")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                if !recordings.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        if autoRetrier.isRetryingAll {
                            ProgressView()
                        } else {
                            Button("Retry All") {
                                Task { await autoRetrier.retryAll() }
                            }
                        }
                    }
                }
            }
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .pendingRecordingsChanged)) { _ in
                reload()
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
    }

    private var list: some View {
        List {
            ForEach(recordings) { recording in
                PendingRecordingRow(
                    recording: recording,
                    title: title(for: recording),
                    isRetrying: dictationViewModel.retryingPendingIDs.contains(recording.id)
                        || noteViewModel.retryingPendingIDs.contains(recording.id),
                    onRetry: { retry(recording) },
                    onDiscard: { discard(recording) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    static func title(
        for recording: PendingRecording,
        recipeName: String?,
        notebookName: String?
    ) -> String {
        switch recording.surface {
        case .dictate:
            return recipeName ?? String(localized: "Dictation")
        case .note:
            let kind = recording.noteEntryID == nil
                ? String(localized: "Voice note")
                : String(localized: "Addition")
            return notebookName.map { "\(kind) · \($0)" } ?? kind
        }
    }

    private func title(for recording: PendingRecording) -> String {
        Self.title(
            for: recording,
            recipeName: recording.workflowID.flatMap {
                dictationViewModel.config.workflowCatalog.workflow(id: $0)?.name
            },
            notebookName: recording.notebookID.flatMap { noteService.notebook(id: $0)?.title }
        )
    }

    private func reload() {
        recordings = store.all()
    }

    private func retry(_ recording: PendingRecording) {
        Task {
            do {
                switch recording.surface {
                case .dictate:
                    _ = try await dictationViewModel.retryPendingRecordingQuietly(recording.id)
                case .note:
                    _ = try await noteViewModel.retryPendingRecording(recording.id)
                }
            } catch is CancellationError {
            } catch {
                retryError = error.localizedDescription
            }
            reload()
        }
    }

    private func discard(_ recording: PendingRecording) {
        switch recording.surface {
        case .dictate: dictationViewModel.discardPendingRecording(recording.id)
        case .note: noteViewModel.discardPendingRecording(recording.id)
        }
    }
}
