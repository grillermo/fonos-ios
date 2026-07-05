import SwiftUI

/// Large circular mic button with recording states.
/// Default interaction is tap; pass `onPressingChanged` to switch the button
/// to press-and-hold (RecordMode.hold) — it fires true on touch-down and
/// false on release.
struct RecordButton: View {
    let state: RecordButton.ButtonState
    let onTap: () -> Void
    var onPressingChanged: ((Bool) -> Void)?

    enum ButtonState: Equatable {
        case idle
        case recording
        case processing
    }

    private let buttonSize: CGFloat = 96

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(state == .recording ? Color.red : Color.orange)
                .frame(width: buttonSize, height: buttonSize)

            // Icon
            switch state {
            case .idle:
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundColor(.white)
            case .recording:
                Image(systemName: "stop.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white)
            case .processing:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.4)
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .contentShape(Circle())
        .gesture(interactionGesture)
        .shadow(
            color: state == .recording ? Color.red.opacity(0.5) : Color.orange.opacity(0.4),
            radius: state == .recording ? 16 : 8,
            x: 0, y: 4
        )
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("record-button")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: return "Record"
        case .recording: return "Stop recording"
        case .processing: return "Processing recording"
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .processing: return "Processing"
        }
    }

    /// Tap by default; touch-down/up reporting when onPressingChanged is set.
    private var interactionGesture: AnyGesture<Void> {
        if let onPressingChanged {
            return AnyGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPressingChanged(true) }
                    .onEnded { _ in onPressingChanged(false) }
                    .map { _ in () }
            )
        }
        return AnyGesture(TapGesture().onEnded { onTap() }.map { _ in () })
    }
}

#Preview {
    VStack(spacing: 32) {
        RecordButton(state: .idle, onTap: {})
        RecordButton(state: .recording, onTap: {})
        RecordButton(state: .processing, onTap: {})
    }
    .padding()
    .background(Color.black)
}
