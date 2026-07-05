import SwiftUI
import SwiftData

/// Shared config storage for the main app, keyboard extension, and background
/// recorder (all read/write the App Group container).
///
/// The main app's dictation mode (`config.activeModeID`) and the keyboard's
/// dictation mode (`kb_active_mode_id`) are kept SEPARATE and persist
/// independently: the keyboard can pick its own mode without the main app's
/// Settings clobbering it, and vice versa. The keyboard override falls back to
/// the main app's mode only until the keyboard picks one for the first time.
enum AppConfigStorage {
    static let appGroupID = "group.com.fonos.ios"
    static let configKey = "app_config"
    static let keyboardModeOverrideKey = "kb_active_mode_id"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    // MARK: - Public API (real defaults)

    static func load() -> AppConfig? {
        load(standard: .standard, shared: sharedDefaults)
    }

    static func save(_ config: AppConfig) {
        save(config, standard: .standard, shared: sharedDefaults)
    }

    /// The keyboard's independently-chosen mode, or nil if it never picked one.
    static func keyboardModeID() -> String? {
        keyboardModeID(shared: sharedDefaults)
    }

    /// Persist the keyboard's chosen mode (owned by the keyboard extension UI).
    static func setKeyboardModeID(_ modeID: String) {
        setKeyboardModeID(modeID, shared: sharedDefaults)
    }

    // MARK: - Testable cores (injectable defaults)

    static func load(standard: UserDefaults, shared: UserDefaults?) -> AppConfig? {
        let data = shared?.data(forKey: configKey) ?? standard.data(forKey: configKey)
        guard let data, let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return nil
        }
        // Note: the keyboard mode override is deliberately NOT applied here — the
        // main app uses its own activeModeID. The background recorder resolves the
        // keyboard mode explicitly via resolveKeyboardMode(...).
        return config
    }

    static func save(_ config: AppConfig, standard: UserDefaults, shared: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        standard.set(data, forKey: configKey)
        shared?.set(data, forKey: configKey)
        // Deliberately does NOT write keyboardModeOverrideKey — the keyboard owns it.
    }

    static func keyboardModeID(shared: UserDefaults?) -> String? {
        let id = shared?.string(forKey: keyboardModeOverrideKey)
        return (id?.isEmpty == false) ? id : nil
    }

    static func setKeyboardModeID(_ modeID: String, shared: UserDefaults?) {
        shared?.set(modeID, forKey: keyboardModeOverrideKey)
    }

    /// Resolve the effective keyboard dictation mode id: the keyboard's own
    /// choice if it made one, otherwise the main app's mode.
    static func resolveKeyboardMode(override: String?, configActiveModeID: String) -> String {
        if let override, !override.isEmpty { return override }
        return configActiveModeID
    }
}

struct ContentView: View {

    enum AppTab: Hashable {
        case dictate, history, notes, settings
    }

    @StateObject private var dictationViewModel = DictationViewModel()
    @State private var selectedTab: AppTab = .dictate
    @State private var pendingConfigImport: PendingConfigImport?
    private let modelContainer: ModelContainer
    private let noteService: NoteService
    @StateObject private var noteViewModel: NoteViewModel

    private struct PendingConfigImport: Identifiable {
        let id = UUID()
        let data: Data
        let summary: ScenarioImportSummary
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let service = NoteService(modelContainer: modelContainer)
        self.noteService = service
        self._noteViewModel = StateObject(wrappedValue: NoteViewModel(noteService: service))
    }

    /// Convenience init for previews/tests — uses in-memory container.
    init() {
        let container = try! ModelContainer(
            for: NoteContainer.self, NoteEntry.self, DictationSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        self.init(modelContainer: container)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DictationView(viewModel: dictationViewModel)
                .tabItem {
                    Label("Dictate", systemImage: "mic.fill")
                }
                .tag(AppTab.dictate)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
                .tag(AppTab.history)

            NotesView(noteService: noteService, noteViewModel: noteViewModel)
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
                .tag(AppTab.notes)

            SettingsView(config: Binding(
                get: { dictationViewModel.config },
                set: { newConfig in
                    dictationViewModel.config = newConfig
                    noteViewModel.config = newConfig
                    AppConfigStorage.save(newConfig)
                }
            ))
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(AppTab.settings)
        }
        .preferredColorScheme(.dark)
        .tint(Color(hex: "#fbbf24"))
        .onAppear {
            dictationViewModel.modelContext = modelContainer.mainContext
            if let saved = AppConfigStorage.load() {
                dictationViewModel.config = saved
            }
            noteViewModel.config = dictationViewModel.config
            AppConfigStorage.save(dictationViewModel.config)
        }
        // fonos://record — widget tap or "Dictate with Fonos" App Intent (spec Flow 2)
        .onReceive(NotificationCenter.default.publisher(for: .fonosStartRecording)) { notification in
            selectedTab = .dictate
            if let modeID = notification.userInfo?["mode"] as? String {
                dictationViewModel.config.activeModeID = modeID
            }
            if !dictationViewModel.isRecording {
                dictationViewModel.startRecording()
            }
        }
        // fonos://note — "Record a Note" App Intent (spec Flow 3); NotesView
        // handles navigating to the requested notebook.
        .onReceive(NotificationCenter.default.publisher(for: .fonosOpenNotes)) { _ in
            selectedTab = .notes
        }
        // fonos://config?d=… — a shared config bundle (e.g. scanned QR). Decode
        // and show a preview; never apply untrusted input silently.
        .onReceive(NotificationCenter.default.publisher(for: .fonosImportConfig)) { notification in
            guard let payload = notification.userInfo?["payload"] as? String,
                  let data = try? ConfigBundleCodec.decode(payload),
                  let summary = try? ScenarioImporter.preview(data: data) else { return }
            pendingConfigImport = PendingConfigImport(data: data, summary: summary)
        }
        .sheet(item: $pendingConfigImport) { pending in
            ConfigImportPreviewView(
                summary: pending.summary,
                onImport: {
                    applyImportedConfig(pending.data)
                    pendingConfigImport = nil
                },
                onCancel: { pendingConfigImport = nil }
            )
        }
    }

    /// Apply an imported config bundle to the live config, Notes VM, and storage.
    private func applyImportedConfig(_ data: Data) {
        guard let (newConfig, _) = try? ScenarioImporter.apply(
            data: data, to: dictationViewModel.config, vocabStore: VocabStore()) else { return }
        dictationViewModel.config = newConfig
        noteViewModel.config = newConfig
        AppConfigStorage.save(newConfig)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [DictationSession.self, NoteContainer.self, NoteEntry.self], inMemory: true)
}
