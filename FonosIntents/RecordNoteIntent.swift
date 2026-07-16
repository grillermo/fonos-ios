import AppIntents
import Foundation
import UIKit

enum RecordNoteIntentLaunchError: LocalizedError, Equatable {
    case invalidDeepLink
    case notebookUnavailable(String)
    case ambiguousNotebookTitle(String)
    case couldNotOpenApp

    var errorDescription: String? {
        switch self {
        case .invalidDeepLink:
            "Fonos could not create the requested note link."
        case .notebookUnavailable(let value):
            "The notebook ‘\(value)’ is no longer available. Choose another notebook in Shortcuts."
        case .ambiguousNotebookTitle(let value):
            "More than one notebook is named ‘\(value)’. Choose the notebook again in Shortcuts."
        case .couldNotOpenApp:
            "Fonos could not open the note recorder."
        }
    }
}

// MARK: - NotebookOptionsProvider

/// Reads the SharedNotebookCatalog so Shortcuts stores each notebook's stable
/// UUID while presenting its human-readable title. Duplicate titles therefore
/// remain distinct and can never route a note to an arbitrary notebook.
struct NotebookOptionsProvider: DynamicOptionsProvider {
    /// Override target for tests. Production uses SharedNotebookCatalog.defaultURL.
    let catalogURL: URL?

    init(catalogURL: URL? = SharedNotebookCatalog.defaultURL) {
        self.catalogURL = catalogURL
    }

    func results() async throws -> IntentItemCollection<String> {
        let entries = SharedNotebookCatalog.read(from: catalogURL)
        let titleCounts = Dictionary(grouping: entries) {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }.mapValues(\.count)
        let items = entries.map { entry in
            let normalizedTitle = entry.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let subtitle: LocalizedStringResource? = titleCounts[normalizedTitle, default: 0] > 1
                ? "Notebook ID \(entry.id.prefix(8))"
                : nil
            return IntentItem(
                entry.id,
                title: "\(entry.title)",
                subtitle: subtitle,
                image: .init(systemName: "note.text")
            )
        }
        return IntentItemCollection(
            sections: [IntentItemSection(items: items)]
        )
    }
}

// MARK: - RecordNoteIntent

/// AppIntent for Shortcuts / Siri / Back Tap: "Record a Note"
///
/// Users can add this intent to Shortcuts or invoke it via Back Tap.
/// The notebook parameter is exposed as a dynamic options list so the user
/// can pick by title rather than entering a UUID.
struct RecordNoteIntent: AppIntent {
    // MARK: - Metadata

    static let title: LocalizedStringResource = "Record a Note"

    static let description = IntentDescription(
        "Opens Fonos and starts recording a voice note.",
        categoryName: "Notes"
    )

    /// Intent opens the app to begin recording.
    static let openAppWhenRun: Bool = true

    // MARK: - Parameters

    /// Stable UUID of the target notebook. The options provider displays its
    /// current title (and a short id when titles collide).
    @Parameter(
        title: "Notebook",
        description: "Which notebook to record into.",
        optionsProvider: NotebookOptionsProvider()
    )
    var notebookId: String?

    // MARK: - Instance accessors (for testability)

    var title: LocalizedStringResource { Self.title }
    var openAppWhenRun: Bool { Self.openAppWhenRun }
    var intentDescription: String? { "Opens Fonos and starts recording a voice note." }

    // MARK: - Perform

    func deepLinkURL(
        catalog entries: [SharedNotebookCatalog.Entry] = SharedNotebookCatalog.read()
    ) throws -> URL {
        guard var components = URLComponents(string: "fonos://note") else {
            throw RecordNoteIntentLaunchError.invalidDeepLink
        }

        if let value = notebookId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            let resolvedID: String
            if let uuid = UUID(uuidString: value) {
                resolvedID = uuid.uuidString
            } else {
                // Backward compatibility for Shortcuts saved by earlier builds,
                // which persisted a title. Never guess when that title is now
                // ambiguous.
                let matches = entries.filter {
                    $0.title.localizedCaseInsensitiveCompare(value) == .orderedSame
                }
                guard matches.count <= 1 else {
                    throw RecordNoteIntentLaunchError.ambiguousNotebookTitle(value)
                }
                guard let entry = matches.first else {
                    throw RecordNoteIntentLaunchError.notebookUnavailable(value)
                }
                resolvedID = entry.id
            }
            components.queryItems = [URLQueryItem(name: "notebook", value: resolvedID)]
        }

        guard let url = components.url else {
            throw RecordNoteIntentLaunchError.invalidDeepLink
        }
        return url
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let url = try deepLinkURL()
        guard await UIApplication.shared.open(url) else {
            throw RecordNoteIntentLaunchError.couldNotOpenApp
        }
        return .result(value: "Fonos opened and requested note recording")
    }
}
