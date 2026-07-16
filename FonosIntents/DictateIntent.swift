import AppIntents
import Foundation
import UIKit

enum DictateIntentLaunchError: LocalizedError, Equatable {
    case invalidDeepLink
    case couldNotOpenApp

    var errorDescription: String? {
        switch self {
        case .invalidDeepLink:
            "Fonos could not create the requested dictation link."
        case .couldNotOpenApp:
            "Fonos could not open the dictation screen."
        }
    }
}

// MARK: - DictateIntent

/// AppIntent for Siri Shortcuts: "Dictate with Fonos"
///
/// Users can add this intent to Shortcuts or invoke it via Siri.
/// Optional parameters allow pre-selecting a processing mode and destination.
struct DictateIntent: AppIntent {
    // MARK: - Metadata

    static let title: LocalizedStringResource = "Dictate with Fonos"

    static let description = IntentDescription(
        "Opens Fonos and starts a dictation session.",
        categoryName: "Dictation"
    )

    /// Intent opens the app to begin recording.
    static let openAppWhenRun: Bool = true

    // MARK: - Parameters

    /// Processing mode: "raw", "polish", "formal", "translate", or "custom".
    @Parameter(title: "Mode", description: "Processing mode for the dictation.", default: "raw")
    var mode: String?

    /// Destination: "clipboard", "messages", "email", etc.
    @Parameter(title: "Destination", description: "Where to send the transcribed text.", default: "clipboard")
    var destination: String?

    // MARK: - Perform

    /// Pure URL construction used by perform and contract tests. Keeping this
    /// separate also makes malformed URL construction an explicit error rather
    /// than a force-unwrap crash.
    func deepLinkURL() throws -> URL {
        guard var components = URLComponents(string: "fonos://record") else {
            throw DictateIntentLaunchError.invalidDeepLink
        }
        var queryItems: [URLQueryItem] = []

        if let mode = mode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mode.isEmpty {
            queryItems.append(URLQueryItem(name: "mode", value: mode))
        }
        if let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines),
           !destination.isEmpty {
            queryItems.append(URLQueryItem(name: "destination", value: destination))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw DictateIntentLaunchError.invalidDeepLink
        }
        return url
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = try deepLinkURL()
        guard await UIApplication.shared.open(url) else {
            throw DictateIntentLaunchError.couldNotOpenApp
        }

        return .result(value: "Fonos opened and requested dictation")
    }
}

// MARK: - Shortcuts Provider

/// Registers intents as app shortcuts so they appear automatically in Shortcuts.
struct FonosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start dictation in \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: RecordNoteIntent(),
            phrases: [
                "Record a note in \(.applicationName)",
                "Take a note with \(.applicationName)"
            ],
            shortTitle: "Record Note",
            systemImageName: "note.text"
        )
    }
}
