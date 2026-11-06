import SwiftUI

/// A failed recording waiting for retry. The play button on the left turns
/// into stop while it plays. The ⋯ button and a long press open the same popup
/// menu, and swiping left discards it.
struct PendingRecordingRow: View {
    let recording: PendingRecording
    let title: String
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDiscard: () -> Void
    @ObservedObject var player = PendingRecordingPlayer.shared

    private static let accent = Color(hex: "#fb923c")

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            playbackButton

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
                if recording.autoRetryStoppedAt != nil {
                    Text("Won't retry automatically")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.5))
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if isRetrying {
                ProgressView()
                    .tint(Self.accent)
                    .accessibilityLabel(Text("Retrying"))
            } else {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Self.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.vertical, -10)

                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#fafaf9").opacity(0.7))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.vertical, -10)
                .accessibilityLabel(Text("Actions for \(title)"))
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
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isRetrying {
                Button(role: .destructive, action: onDiscard) {
                    Label("Discard", systemImage: "trash")
                }
            }
        }
    }

    private var playbackButton: some View {
        let isPlaying = player.playingID == recording.id
        return Button {
            player.toggle(recording.id)
        } label: {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(Self.accent)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.vertical, -7)
        .accessibilityLabel(isPlaying ? Text("Stop") : Text("Play"))
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRetry) {
            Label("Retry", systemImage: "arrow.clockwise")
        }
        if !recording.lastError.isEmpty {
            Button {
                UIPasteboard.general.string = recording.lastError
            } label: {
                Label("Copy error", systemImage: "doc.on.doc")
            }
        }
        Button(role: .destructive, action: onDiscard) {
            Label("Discard", systemImage: "trash")
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds).rounded()) : 0
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview {
    func sample(_ error: String) -> PendingRecording {
        PendingRecording(
            id: UUID(), surface: .dictate, workflowID: nil, notebookID: nil,
            createdAt: Date(), lastError: error, attempts: 1, durationSeconds: 75
        )
    }
    return VStack(spacing: 12) {
        PendingRecordingRow(recording: sample("The network connection was lost."),
                            title: "Dictation", isRetrying: false, onRetry: {}, onDiscard: {})
        PendingRecordingRow(recording: sample("The network connection was lost."),
                            title: "Dictation", isRetrying: true, onRetry: {}, onDiscard: {})
        PendingRecordingRow(recording: sample(String(repeating: "Transcription service returned an unexpected response. ", count: 4)),
                            title: "Dictation", isRetrying: false, onRetry: {}, onDiscard: {})
    }
    .padding()
    .background(Color.black)
    .preferredColorScheme(.dark)
}
