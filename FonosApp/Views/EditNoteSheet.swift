import SwiftUI

/// Opens a note's text for editing, with the cursor at the end so new text
/// can be appended straight away, by typing or with the microphone. The text
/// is saved every second and when the sheet is swiped closed, so there is no
/// Done or Cancel; closing the app loses at most the last second.
struct EditNoteSheet: View {
    let notebook: NoteContainer
    @ObservedObject var noteViewModel: NoteViewModel
    let onSave: (String) throws -> Void

    private let entryID: UUID
    // In @State because this view is rebuilt from the note, which the
    // autosaves change: the first autosaver has to outlive those rebuilds.
    @State private var autosaver: NoteAutosaver
    @State private var text: String
    @State private var showRecordSheet = false
    @State private var showCopied = false
    @State private var copiedReset: Task<Void, Never>?
    @FocusState private var isEditing: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(
        entry: NoteEntry,
        notebook: NoteContainer,
        noteViewModel: NoteViewModel,
        onSave: @escaping (String) throws -> Void
    ) {
        let shownText = entry.processedText ?? entry.rawText
        self.notebook = notebook
        self.noteViewModel = noteViewModel
        self.onSave = onSave
        self.entryID = entry.id
        self._autosaver = State(initialValue: NoteAutosaver(originalText: shownText, save: onSave))
        self._text = State(initialValue: shownText)
    }

    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Color(hex: "#1a1917").ignoresSafeArea()

                ResultTextEditor(text: $text, isFocused: $isEditing, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    // Keeps the last lines clear of the microphone.
                    .padding(.bottom, 84)

                MicActionButton {
                    isEditing = false
                    showRecordSheet = true
                }
                .padding(24)

                HStack(spacing: 12) {
                    // Shares the text as shown (edits included) through the system
                    // share sheet, where Shortcuts with "Show in Share Sheet" appear.
                    ShareLink(item: text) {
                        roundIcon("square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")

                    // Copies the text as shown (edits included); the icon turns
                    // into a checkmark for a moment to confirm it.
                    Button(action: copyText) {
                        roundIcon(showCopied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityLabel(showCopied ? "Copied" : "Copy")
                }
                .disabled(isBlank)
                .opacity(isBlank ? 0.4 : 1)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { isEditing = true }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                autosaver.autosave(text)
            }
        }
        // The tick stops while the app is suspended, so save on the way out.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { autosaver.autosave(text) }
        }
        // Swiping the sheet down closes it; keep the last edit.
        .onDisappear { autosaver.autosave(text) }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showRecordSheet) {
            RecordNoteSheet(
                notebook: notebook,
                noteViewModel: noteViewModel,
                appendingTo: entryID,
                onTranscribed: { text = NoteViewModel.appending($0, to: text) },
                onDismiss: { showRecordSheet = false }
            )
        }
    }

    private func roundIcon(_ systemName: String) -> some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#fafaf9").opacity(0.1))
                .frame(width: 60, height: 60)
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(Color(hex: "#fbbf24"))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func copyText() {
        UIPasteboard.general.string = text
        withAnimation { showCopied = true }
        copiedReset?.cancel()
        copiedReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { showCopied = false }
        }
    }

}
