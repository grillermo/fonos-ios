import Foundation
import SwiftUI

enum KeyboardReadyVisualState: Equatable, Sendable {
    case inactive
    case ready
    case recording
    case paused
    case finishing
    case expired
}

/// A single presentation model keeps the settings control and app-wide banner
/// honest about whether the microphone is ready, actively capturing, paused,
/// or merely finishing an already accepted utterance.
struct KeyboardReadyPresentation: Equatable, Sendable {
    let state: KeyboardReadyVisualState

    init(
        readinessStatus: KeyboardIPC.ReadinessStatus,
        operationStatus: String? = nil
    ) {
        switch readinessStatus {
        case .inactive:
            state = .inactive
        case .ready:
            let operation = operationStatus?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            state = operation == "recording" ? .recording : .ready
        case .paused:
            state = .paused
        case .finishing:
            state = .finishing
        case .expired:
            state = .expired
        }
    }

    var iconName: String {
        switch state {
        case .inactive: "mic.slash"
        case .ready: "mic.fill"
        case .recording: "waveform"
        case .paused: "pause.fill"
        case .finishing: "hourglass"
        case .expired: "clock.badge.exclamationmark"
        }
    }

    var title: String {
        switch state {
        case .inactive: String(localized: "Keyboard Ready off")
        case .ready: String(localized: "Keyboard Ready")
        case .recording: String(localized: "Recording from Fonos keyboard")
        case .paused: String(localized: "Keyboard Ready paused")
        case .finishing: String(localized: "Finishing current dictation")
        case .expired: String(localized: "Keyboard Ready expired")
        }
    }

    var usesActiveMicrophoneStyle: Bool {
        state == .ready || state == .recording
    }

    func detail(remainingSeconds: Int) -> String {
        let remaining = max(0, remainingSeconds)
        let minutes = Int64(remaining / 60)
        let seconds = Int64(remaining % 60)
        switch state {
        case .inactive:
            return String(localized: "Start a session to use keyboard dictation.")
        case .ready:
            return String(
                format: String(localized: "Microphone active · %lld:%02lld"),
                minutes,
                seconds
            )
        case .recording:
            return String(
                format: String(localized: "Microphone recording · %lld:%02lld remaining"),
                minutes,
                seconds
            )
        case .paused:
            return String(
                format: String(localized: "Microphone paused · %lld:%02lld remaining"),
                minutes,
                seconds
            )
        case .finishing:
            return String(localized: "No new dictations · Finishing the current one")
        case .expired:
            return String(localized: "Start a new session to use keyboard dictation.")
        }
    }
}

private enum KeyboardReadyOperationStatusReader {
    private static let appGroupID = KeyboardIPC.appGroupID

    static func current() -> String? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let url = directory.appendingPathComponent(KeyboardIPC.FileName.status)
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// Explicit control for the containing app's time-limited keyboard audio
/// bridge. Starting this session keeps iOS microphone input active so the
/// custom keyboard can begin an utterance without switching apps; idle audio
/// buffers are discarded by `BackgroundRecordingService`.
struct KeyboardReadyControl: View {
    @State private var session: KeyboardReadySession?
    @State private var status: KeyboardIPC.ReadinessStatus = .inactive
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session, session.isActive() || status == .finishing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let presentation = KeyboardReadyPresentation(
                        readinessStatus: status,
                        operationStatus: KeyboardReadyOperationStatusReader.current()
                    )
                    let detail = presentation.detail(
                        remainingSeconds: remainingSeconds(
                            until: session.expiresAt,
                            now: context.date
                        )
                    )
                    HStack(spacing: 12) {
                        Image(systemName: presentation.iconName)
                            .foregroundStyle(
                                presentation.usesActiveMicrophoneStyle
                                    ? Color.orange
                                    : Color.secondary
                            )
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(presentation.title)
                                .font(.body.weight(.medium))
                            Text(detail)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Stop", role: .destructive) {
                            BackgroundRecordingService.shared.disableKeyboardReadySession()
                            refresh()
                        }
                        .buttonStyle(.borderless)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Keyboard Ready, \(presentation.title), \(detail)")
                }
            } else {
                Button {
                    startSession()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "keyboard.badge.ellipsis")
                            .foregroundStyle(Color.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start Keyboard Ready")
                                .foregroundStyle(.primary)
                            Text("Keep Fonos available for no-jump keyboard dictation for 15 minutes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if isStarting {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(isStarting)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .keyboardReadySessionDidChange)) { _ in
            refresh()
        }
        .alert(
            "Keyboard Ready Couldn’t Start",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    @MainActor
    private func refresh() {
        session = BackgroundRecordingService.shared.keyboardReadySession
        status = BackgroundRecordingService.shared.keyboardReadinessStatus
    }

    private func startSession() {
        isStarting = true
        Task { @MainActor in
            defer { isStarting = false }
            do {
                _ = try await BackgroundRecordingService.shared.enableKeyboardReadySession()
                refresh()
            } catch {
                errorMessage = error.localizedDescription
                refresh()
            }
        }
    }

    private func remainingSeconds(until expiration: Date, now: Date) -> Int {
        max(0, Int(expiration.timeIntervalSince(now).rounded(.up)))
    }
}

/// Compact, app-wide disclosure shown whenever microphone input is held for
/// keyboard dictation. It remains visible on every tab while the app is open.
struct KeyboardReadyBanner: View {
    @State private var session: KeyboardReadySession?
    @State private var status: KeyboardIPC.ReadinessStatus = .inactive

    var body: some View {
        Group {
            if let session, session.isActive() || status == .finishing {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let presentation = KeyboardReadyPresentation(
                        readinessStatus: status,
                        operationStatus: KeyboardReadyOperationStatusReader.current()
                    )
                    let detail = presentation.detail(
                        remainingSeconds: remainingSeconds(
                            until: session.expiresAt,
                            now: context.date
                        )
                    )
                    HStack(spacing: 10) {
                        Image(systemName: presentation.iconName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(
                                presentation.usesActiveMicrophoneStyle
                                    ? Color.black
                                    : Color.secondary
                            )
                            .frame(width: 26, height: 26)
                            .background(
                                Circle().fill(
                                    presentation.usesActiveMicrophoneStyle
                                        ? Color.orange
                                        : Color.secondary.opacity(0.14)
                                )
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(presentation.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(detail)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Stop") {
                            BackgroundRecordingService.shared.disableKeyboardReadySession()
                            refresh()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.35)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(presentation.title), \(detail)")
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .keyboardReadySessionDidChange)) { _ in
            refresh()
        }
    }

    @MainActor
    private func refresh() {
        session = BackgroundRecordingService.shared.keyboardReadySession
        status = BackgroundRecordingService.shared.keyboardReadinessStatus
    }

    private func remainingSeconds(until expiration: Date, now: Date) -> Int {
        max(0, Int(expiration.timeIntervalSince(now).rounded(.up)))
    }
}
