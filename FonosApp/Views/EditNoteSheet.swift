import SwiftUI

/// Opens a note's text for editing, with the cursor at the end so new text
/// can be appended straight away, by typing or with the microphone.
struct EditNoteSheet: View {
    let notebook: NoteContainer
    @ObservedObject var noteViewModel: NoteViewModel
    let onSave: (String) throws -> Void

    private let originalText: String
    @State private var text: String
    @State private var saveError: String?
    @State private var showRecordSheet = false
    @FocusState private var isEditing: Bool
    @Environment(\.dismiss) private var dismiss

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
        self.originalText = shownText
        self._text = State(initialValue: shownText)
    }

    private var hasChanges: Bool { text != originalText }
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
            }
            .navigationTitle("Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .disabled(isBlank)
                }
            }
        }
        .onAppear { isEditing = true }
        // A stray swipe must not discard what was typed.
        .interactiveDismissDisabled(hasChanges)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showRecordSheet) {
            RecordNoteSheet(
                notebook: notebook,
                noteViewModel: noteViewModel,
                onTranscribed: { text = NoteViewModel.appending($0, to: text) },
                onDismiss: { showRecordSheet = false }
            )
        }
        .alert(
            "Note Could Not Be Saved",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        guard hasChanges else {
            dismiss()
            return
        }
        do {
            try onSave(text)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
