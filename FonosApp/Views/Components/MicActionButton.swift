import SwiftUI

/// The yellow floating microphone that starts a voice note recording.
struct MicActionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        .accessibilityLabel("Record")
        .accessibilityIdentifier("noteRecordButton")
    }
}
