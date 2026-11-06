import SwiftUI

/// Editable transcript text, shared by the Dictate result card and the note
/// editor so both behave and look the same.
struct ResultTextEditor: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    var maxHeight: CGFloat = 200

    var body: some View {
        TextEditor(text: $text)
            .focused(isFocused)
            .font(.system(size: 16))
            .foregroundColor(Color(hex: "#fafaf9"))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 80, maxHeight: maxHeight)
            .padding(.horizontal, -5)
    }
}
