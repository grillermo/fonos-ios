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
#if DEBUG
            if ScreenshotDemoData.isEnabled {
                dictationViewModel.config = ScreenshotDemoData.seed(
                    modelContainer: modelContainer
                )
            }
#endif
            noteViewModel.config = dictationViewModel.config
#if DEBUG
            if !ScreenshotDemoData.isEnabled {
                AppConfigStorage.save(dictationViewModel.config)
            }
#else
            AppConfigStorage.save(dictationViewModel.config)
#endif
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

#if DEBUG
enum ScreenshotDemoData {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FONOS_SCREENSHOT_MODE"] == "1"
    }

    @MainActor
    static func seed(modelContainer: ModelContainer) -> AppConfig {
        let context = modelContainer.mainContext
        var seededConfig = seedConfig()
        seedHistoryIfNeeded(in: context)
        seedNotesIfNeeded(in: context)
        seededConfig.activeModeID = seededConfig.activeModeID.isEmpty ? "polish" : seededConfig.activeModeID
        return seededConfig
    }

    private static func seedConfig() -> AppConfig {
        // Screenshot mode must never inherit model names, endpoints, or other
        // state from the simulator's real persisted configuration.
        var seeded = AppConfig()
        let stt = ModelProfile(
            id: "demo-whisper-stt",
            name: "Demo Whisper STT",
            provider: "custom",
            modelID: "whisper-large-v3",
            baseURL: "https://api.example.com",
            capabilities: ["stt"]
        )
        let llm = ModelProfile(
            id: "demo-gpt-llm",
            name: "Demo GPT LLM",
            provider: "openai",
            modelID: "gpt-4o-mini",
            baseURL: "https://api.openai.com",
            capabilities: ["llm"]
        )
        seeded.modelProfiles = [stt, llm]
        seeded.sttProfile = stt.id
        seeded.llmProfile = llm.id
        seeded.activeModeID = "polish"
        seeded.translateTargetLanguage = "English"
        return seeded
    }

    @MainActor
    private static func seedHistoryIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<DictationSession>())) ?? []
        guard existing.isEmpty else { return }
        let now = Date()
        let sessions = [
            DictationSession(
                date: now.addingTimeInterval(-8 * 60),
                mode: "polish",
                inputText: "um can you send the launch checklist to maya and ask her to review the privacy labels before friday",
                outputText: "Please send the launch checklist to Maya and ask her to review the privacy labels before Friday.",
                destination: "clipboard",
                latencyMs: 820
            ),
            DictationSession(
                date: now.addingTimeInterval(-38 * 60),
                mode: "formal",
                inputText: "hey thanks for the quick pass i fixed the keyboard issue and will send a new build tonight",
                outputText: "Thank you for the quick review. I fixed the keyboard issue and will send a new build tonight.",
                destination: "messages",
                latencyMs: 1040
            ),
            DictationSession(
                date: now.addingTimeInterval(-96 * 60),
                mode: "translate",
                inputText: "我们明天上午同步一下发布材料和截图顺序",
                outputText: "Let's sync tomorrow morning on the release materials and screenshot order.",
                destination: "share",
                latencyMs: 1180
            )
        ]
        sessions.forEach(context.insert)
        try? context.save()
    }

    @MainActor
    private static func seedNotesIfNeeded(in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<NoteContainer>())) ?? []
        guard existing.isEmpty else { return }
        let now = Date()
        let notebooks = [
            NoteContainer(
                title: "Launch Notes",
                processingMode: "polish",
                createdAt: now.addingTimeInterval(-5 * 24 * 60 * 60),
                updatedAt: now.addingTimeInterval(-12 * 60),
                systemPrompt: "Turn voice notes into concise launch-ready action items."
            ),
            NoteContainer(
                title: "Meeting Recaps",
                processingMode: "summarize",
                createdAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
                updatedAt: now.addingTimeInterval(-54 * 60),
                systemPrompt: "Summarize decisions, owners, and next steps."
            ),
            NoteContainer(
                title: "Ideas",
                processingMode: "raw",
                createdAt: now.addingTimeInterval(-14 * 24 * 60 * 60),
                updatedAt: now.addingTimeInterval(-2 * 60 * 60),
                systemPrompt: ""
            )
        ]
        notebooks.forEach(context.insert)

        let entries = [
            NoteEntry(
                createdAt: now.addingTimeInterval(-12 * 60),
                rawText: "Need final screenshots, privacy labels, review notes, and one clean TestFlight build before submission.",
                processedText: "Release prep: finalize screenshots, complete privacy labels, confirm review notes, and upload one clean TestFlight build.",
                containerId: notebooks[0].id,
                mode: "polish",
                durationMs: 9200,
                language: "en-US"
            ),
            NoteEntry(
                createdAt: now.addingTimeInterval(-54 * 60),
                rawText: "The main question is whether keyboard dictation should require the app to stay open during review.",
                processedText: "Decision: explain in review notes that the keyboard extension communicates with the main app for dictation.",
                containerId: notebooks[1].id,
                mode: "summarize",
                durationMs: 12800,
                language: "en-US"
            ),
            NoteEntry(
                createdAt: now.addingTimeInterval(-2 * 60 * 60),
                rawText: "Maybe add a quick mode switch on the keyboard after 1.0 so translation and polish are easier to reach.",
                processedText: nil,
                containerId: notebooks[2].id,
                mode: "raw",
                durationMs: 7400,
                language: "en-US"
            )
        ]
        entries.forEach(context.insert)
        try? context.save()
    }
}
#endif
