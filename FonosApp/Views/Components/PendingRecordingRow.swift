import SwiftUI

/// A failed recording waiting for retry. The ⋯ button and a long press open
/// the same popup menu.
struct PendingRecordingRow: View {
    let recording: PendingRecording
    let title: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDiscard: () -> Void

    private static let accent = Color(hex: "#fb923c")

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 18))
                .foregroundColor(Self.accent)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Color(hex: "#fafaf9"))
                    Text(Self.durationText(recording.durationSeconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.5))
                }
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#fafaf9").opacity(0.5))
                Text(recording.lastError)
                    .font(.system(size: 12))
                    .foregroundColor(Self.accent.opacity(0.9))
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isRetrying {
                ProgressView()
                    .tint(Self.accent)
            } else {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.7))
                }
                .accessibilityLabel(Text("Pending recording actions"))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Self.accent.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Self.accent.opacity(0.3), lineWidth: 1)
                )
        )
        .contextMenu {
            if !isRetrying { menuItems }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRetry) {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        Button {
            UIPasteboard.general.string = recording.lastError
        } label: {
            Label("Copy error", systemImage: "doc.on.doc")
        }
        Button(role: .destructive, action: onDiscard) {
            Label("Discard", systemImage: "trash")
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
