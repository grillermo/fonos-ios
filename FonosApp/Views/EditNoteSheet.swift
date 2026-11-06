import SwiftUI

/// Opens a note's text for editing, with the cursor at the end so new text
/// can be appended straight away.
struct EditNoteSheet: View {
    let onSave: (String) throws -> Void

    private let originalText: String
    @State private var text: String
    @State private var saveError: String?
    @FocusState private var isEditing: Bool
    @Environment(\.dismiss) private var dismiss

    init(entry: NoteEntry, onSave: @escaping (String) throws -> Void) {
        let shownText = entry.processedText ?? entry.rawText
        self.onSave = onSave
        self.originalText = shownText
        self._text = State(initialValue: shownText)
    }

    private var hasChanges: Bool { text != originalText }
    private var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#1a1917").ignoresSafeArea()

                ResultTextEditor(text: $text, isFocused: $isEditing, maxHeight: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
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
