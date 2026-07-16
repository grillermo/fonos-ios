// NoteINV09: RecordNoteIntent AppIntent compiles and is discoverable.
//
// Verifier: auto
// Level: unit (metadata, registration, options, and deep-link contracts)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/NoteINV09IntentTests

import Testing
import AppIntents
@testable import FonosApp

// MARK: - Tests

struct NoteINV09IntentTests {

    // MARK: - Level 2: Unit — title is non-empty

    @Test("RecordNoteIntent.title is non-empty")
    func titleNonEmpty() throws {
        let intent = RecordNoteIntent()
        let titleString = String(localized: intent.title)
        #expect(!titleString.isEmpty, "RecordNoteIntent.title must not be empty")
    }

    // MARK: - Level 2: Unit — description is non-empty

    @Test("RecordNoteIntent has a non-empty description string")
    func descriptionNonEmpty() throws {
        let intent = RecordNoteIntent()
        let description = try #require(intent.intentDescription)
        #expect(!description.isEmpty, "RecordNoteIntent description must not be empty")
    }

    // MARK: - Level 2: Unit — openAppWhenRun is true

    @Test("RecordNoteIntent.openAppWhenRun is true")
    func openAppWhenRunIsTrue() throws {
        // Back Tap / Shortcuts must bring the app to foreground so the user sees the
        // recording UI immediately. openAppWhenRun must be true.
        let intent = RecordNoteIntent()
        #expect(intent.openAppWhenRun == true)
    }

    // MARK: - v2: AppShortcuts registration & Notebook options provider

    @Test("FonosShortcuts.appShortcuts registers at least two intents (Dictate + RecordNote)")
    func appShortcutsRegistration() {
        // The collection's count is the only public surface — phrases is internal.
        // Both DictateIntent and RecordNoteIntent should be wired up.
        let count = FonosShortcuts.appShortcuts.reduce(into: 0) { acc, _ in acc += 1 }
        #expect(count >= 2)
    }

    @Test("NotebookOptionsProvider stores UUID values and displays catalog titles")
    func optionsProviderReadsCatalog() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opts-test-\(UUID().uuidString).json")
        try SharedNotebookCatalog.write([
            SharedNotebookCatalog.Entry(id: "id1", title: "Work"),
            SharedNotebookCatalog.Entry(id: "id2", title: "Personal")
        ], to: url)

        let provider = NotebookOptionsProvider(catalogURL: url)
        let results = try await provider.results()
        #expect(results.items.sorted() == ["id1", "id2"])
        let titles = results.sections
            .flatMap(\.items)
            .map { String(localized: $0.description.title) }
        #expect(titles.sorted() == ["Personal", "Work"])
    }

    @Test("NotebookOptionsProvider returns empty array when catalog file is missing")
    func optionsProviderEmptyWhenMissing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")
        let provider = NotebookOptionsProvider(catalogURL: url)
        let results = try await provider.results()
        #expect(results.items.isEmpty)
    }

    @Test("RecordNoteIntent preserves the selected notebook UUID")
    func recordNoteIntentBuildsTargetedURL() throws {
        let id = UUID()
        let intent = RecordNoteIntent()
        intent.notebookId = id.uuidString

        let url = try intent.deepLinkURL(catalog: [
            SharedNotebookCatalog.Entry(id: id.uuidString, title: "Work")
        ])
        let components = try #require(URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ))
        #expect(url.host == "note")
        #expect(components.queryItems?.first(where: { $0.name == "notebook" })?.value
                == id.uuidString)
    }

    @Test("duplicate notebook titles remain distinct and legacy title selection fails safely")
    func duplicateNotebookTitlesAreDisambiguated() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let entries = [
            SharedNotebookCatalog.Entry(id: firstID.uuidString, title: "Work"),
            SharedNotebookCatalog.Entry(id: secondID.uuidString, title: "Work")
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duplicate-opts-\(UUID().uuidString).json")
        try SharedNotebookCatalog.write(entries, to: url)

        let results = try await NotebookOptionsProvider(catalogURL: url).results()
        #expect(Set(results.items) == Set([firstID.uuidString, secondID.uuidString]))
        let items = results.sections.flatMap(\.items)
        #expect(items.allSatisfy { $0.description.subtitle != nil })

        let selectedByID = RecordNoteIntent()
        selectedByID.notebookId = secondID.uuidString
        let selectedURL = try selectedByID.deepLinkURL(catalog: entries)
        let selectedComponents = try #require(URLComponents(
            url: selectedURL,
            resolvingAgainstBaseURL: false
        ))
        #expect(selectedComponents.queryItems?.first(where: { $0.name == "notebook" })?.value
                == secondID.uuidString)

        let legacyTitle = RecordNoteIntent()
        legacyTitle.notebookId = "Work"
        #expect(throws: RecordNoteIntentLaunchError.ambiguousNotebookTitle("Work")) {
            try legacyTitle.deepLinkURL(catalog: entries)
        }
    }

    @Test("RecordNoteIntent rejects a stale notebook selection")
    func recordNoteIntentRejectsUnknownNotebook() {
        let intent = RecordNoteIntent()
        intent.notebookId = "Deleted notebook"

        #expect(throws: RecordNoteIntentLaunchError.notebookUnavailable("Deleted notebook")) {
            try intent.deepLinkURL(catalog: [])
        }
    }

    @Test("DictateIntent includes mode and one-shot destination in its deep link")
    func dictateIntentBuildsCompleteURL() throws {
        let intent = DictateIntent()
        intent.mode = "formal"
        intent.destination = "email"

        let url = try intent.deepLinkURL()
        let components = try #require(URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ))
        #expect(url.host == "record")
        #expect(components.queryItems?.first(where: { $0.name == "mode" })?.value == "formal")
        #expect(components.queryItems?.first(where: { $0.name == "destination" })?.value == "email")
    }
}
