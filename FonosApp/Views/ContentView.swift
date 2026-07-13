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
    static let appGroupID = KeyboardIPC.appGroupID
    static let configKey = KeyboardIPC.DefaultsKey.appConfig
    static let keyboardModeOverrideKey = KeyboardIPC.DefaultsKey.modeOverride
    static let keyboardWorkflowOverrideKey = KeyboardIPC.DefaultsKey.workflowOverride
    static let keyboardWorkflowManifestKey = KeyboardIPC.DefaultsKey.workflowManifest

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

    /// The keyboard's workflow-authoritative selection. The legacy mode key
    /// remains mirrored by the extension for older app builds.
    static func keyboardWorkflowID() -> String? {
        keyboardWorkflowID(shared: sharedDefaults)
    }

    // MARK: - Testable cores (injectable defaults)

    static func load(standard: UserDefaults, shared: UserDefaults?) -> AppConfig? {
        let data = shared?.data(forKey: configKey) ?? standard.data(forKey: configKey)
        guard let data, var config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return nil
        }
        // Materialize desktop-compatible workflow definitions exactly once on
        // upgrade (and reconcile any legacy mode added by an older build).
        // Persist immediately so the keyboard/background process sees the same
        // recipe identities as the foreground app.
        if WorkflowMigration.migrate(&config) {
            save(config, standard: standard, shared: shared)
        }
        // The keyboard override is deliberately not applied here: the main app
        // owns activeModeID, while the background recorder resolves the keyboard's
        // workflow override explicitly.
        return config
    }

    static func save(_ config: AppConfig, standard: UserDefaults, shared: UserDefaults?) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        standard.set(data, forKey: configKey)
        shared?.set(data, forKey: configKey)
        if let manifest = try? JSONEncoder().encode(keyboardWorkflowManifest(config: config)) {
            standard.set(manifest, forKey: keyboardWorkflowManifestKey)
            shared?.set(manifest, forKey: keyboardWorkflowManifestKey)
        }
        // Deliberately does NOT write keyboardModeOverrideKey — the keyboard owns it.
    }

    /// Prevalidated picker data for the extension. The extension cannot link
    /// the app's workflow engine, so publishing this manifest prevents its
    /// lightweight decoder from advertising a recipe the main app would
    /// reject (malformed props, missing explicit profile, unsupported output).
    static func keyboardWorkflowManifest(config: AppConfig) -> [KeyboardIPC.WorkflowManifestEntry] {
        let catalog = config.workflowCatalog
        return catalog.workflows.compactMap { workflow in
            guard (try? VoiceWorkflowOperationalValidator.validateMicrophone(
                definition: workflow,
                catalog: catalog,
                config: config
            )) != nil else { return nil }
            return KeyboardIPC.WorkflowManifestEntry(
                id: workflow.id,
                name: workflow.name,
                icon: workflow.icon
            )
        }
    }

    static func keyboardModeID(shared: UserDefaults?) -> String? {
        let id = shared?.string(forKey: keyboardModeOverrideKey)
        return (id?.isEmpty == false) ? id : nil
    }

    static func keyboardWorkflowID(shared: UserDefaults?) -> String? {
        let id = shared?.string(forKey: keyboardWorkflowOverrideKey)
        return (id?.isEmpty == false) ? id : nil
    }

    static func setKeyboardModeID(_ modeID: String, shared: UserDefaults?) {
        shared?.set(modeID, forKey: keyboardModeOverrideKey)
    }

    static func setKeyboardWorkflowID(_ workflowID: String, shared: UserDefaults?) {
        shared?.set(workflowID, forKey: keyboardWorkflowOverrideKey)
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
        do {
            let container = try ModelContainer(
                for: NoteContainer.self, NoteEntry.self, DictationSession.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            self.init(modelContainer: container)
        } catch {
            fatalError("Failed to create the in-memory preview container: \(error)")
        }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            KeyboardReadyBanner()
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
        // Dictate chips and deep links mutate the view model directly rather
        // than going through Settings' Binding. Persist every workflow change
        // here so app restart and the keyboard read the same authority.
        .onChange(of: dictationViewModel.config) { _, newConfig in
            noteViewModel.config = newConfig
#if DEBUG
            if !ScreenshotDemoData.isEnabled {
                AppConfigStorage.save(newConfig)
            }
#else
            AppConfigStorage.save(newConfig)
#endif
        }
        // fonos://record — widget tap or "Dictate with Fonos" App Intent (spec Flow 2)
        .onReceive(NotificationCenter.default.publisher(for: .fonosStartRecording)) { notification in
            selectedTab = .dictate
            if let modeID = notification.userInfo?["mode"] as? String {
                // `mode` remains the public deep-link query name for
                // compatibility, but accepts either a recipe id or a legacy
                // mode id and always selects the workflow authority.
                dictationViewModel.selectMode(id: modeID)
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
        WorkflowMigration.migrate(&seeded)
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
                workflowID: "wf.voice.polish",
                workflowName: "Polish",
                mode: "polish",
                inputText: "um can you send the launch checklist to maya and ask her to review the privacy labels before friday",
                outputText: "Please send the launch checklist to Maya and ask her to review the privacy labels before Friday.",
                destination: "clipboard",
                latencyMs: 820
            ),
            DictationSession(
                date: now.addingTimeInterval(-38 * 60),
                workflowID: "wf.voice.formal",
                workflowName: "Formal",
                mode: "formal",
                inputText: "hey thanks for the quick pass i fixed the keyboard issue and will send a new build tonight",
                outputText: "Thank you for the quick review. I fixed the keyboard issue and will send a new build tonight.",
                destination: "messages",
                latencyMs: 1040
            ),
            DictationSession(
                date: now.addingTimeInterval(-96 * 60),
                workflowID: "wf.voice.translate",
                workflowName: "Translate",
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
                processedText: "Release prep: finalize screenshots, complete privacy labels, "
                    + "confirm review notes, and upload one clean TestFlight build.",
                containerId: notebooks[0].id,
                mode: "polish",
                durationMs: 9200,
                language: "en-US"
            ),
            NoteEntry(
                createdAt: now.addingTimeInterval(-54 * 60),
                rawText: "The main question is whether keyboard dictation should require the app to stay open during review.",
                processedText: "Decision: explain in review notes that the keyboard extension "
                    + "communicates with the main app for dictation.",
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
