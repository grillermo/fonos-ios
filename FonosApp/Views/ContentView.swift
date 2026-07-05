import SwiftUI
import SwiftData

enum AppConfigStorage {
    static let appGroupID = "group.com.fonos.ios"
    static let configKey = "app_config"
    static let keyboardModeOverrideKey = "kb_active_mode_id"

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func load() -> AppConfig? {
        let data = sharedDefaults?.data(forKey: configKey)
            ?? UserDefaults.standard.data(forKey: configKey)

        guard let data,
              var config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return nil
        }

        if let modeID = sharedDefaults?.string(forKey: keyboardModeOverrideKey),
           !modeID.isEmpty {
            config.activeModeID = modeID
        }

        return config
    }

    static func save(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: configKey)
        sharedDefaults?.set(data, forKey: configKey)
        sharedDefaults?.set(config.activeModeID, forKey: keyboardModeOverrideKey)
    }
}

struct ContentView: View {

    enum AppTab: Hashable {
        case dictate, history, notes, settings
    }

    @StateObject private var dictationViewModel = DictationViewModel()
    @State private var selectedTab: AppTab = .dictate
    private let modelContainer: ModelContainer
    private let noteService: NoteService
    @StateObject private var noteViewModel: NoteViewModel

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
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [DictationSession.self, NoteContainer.self, NoteEntry.self], inMemory: true)
}
