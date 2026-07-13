import SwiftUI
import SwiftData

@main
struct FonosApp: App {

    private static let appGroupID = KeyboardIPC.appGroupID

    let modelContainer: ModelContainer

    init() {
        // Register IPC observers only. Microphone input starts after the user
        // explicitly enables Keyboard Ready or begins foreground dictation.
        BackgroundRecordingService.shared.register()
        do {
            try Self.ensureSharedApplicationSupportDirectory()
            let schema = Schema([DictationSession.self, NoteContainer.self, NoteEntry.self])
#if DEBUG
            let configuration = ModelConfiguration(
                isStoredInMemoryOnly: ScreenshotDemoData.isEnabled
            )
#else
            let configuration = ModelConfiguration()
#endif
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
            BackgroundRecordingService.shared.configure(
                modelContext: modelContainer.mainContext
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(modelContainer: modelContainer)
                .modelContainer(modelContainer)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    // MARK: - Deep Link Handling

    /// Handles incoming URLs, e.g. `fonos://record` from the Home Screen widget or Siri Shortcuts.
    private func handleDeepLink(_ url: URL) {
        DeepLinkRouter.handle(url)
    }

    private static func ensureSharedApplicationSupportDirectory() throws {
        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return
        }

        let applicationSupportURL = groupURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
    }
}
