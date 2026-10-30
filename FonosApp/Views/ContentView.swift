import SwiftUI
import SwiftData

/// Shared config storage for the main app, keyboard extension, and background
/// recorder (all read/write the App Group container).
///
/// The main app and keyboard keep separate workflow selections. The legacy
/// keyboard mode key remains readable only for compatibility with older
/// extension builds.
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
        // Materialize desktop-compatible workflow definitions during the
        // one-way legacy upgrade. Schema 3 never re-reads retired Mode data.
        // Persist immediately so the keyboard/background process sees the same
        // recipe identities as the foreground app.
        if WorkflowMigration.migrate(&config) {
            save(config, standard: standard, shared: shared)
        }
        // The keyboard override is deliberately not applied here: the main app
        // owns activeVoiceWorkflowID while the background recorder resolves the
        // keyboard workflow override explicitly.
        return config
    }

    static func save(_ config: AppConfig, standard: UserDefaults, shared: UserDefaults?) {
        var persistedConfig = config
        WorkflowMigration.migrate(&persistedConfig)
        guard let data = try? JSONEncoder().encode(persistedConfig) else { return }
        standard.set(data, forKey: configKey)
        shared?.set(data, forKey: configKey)
        if let manifest = try? JSONEncoder().encode(
            keyboardWorkflowManifest(config: persistedConfig)
        ) {
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
            guard config.isVoiceWorkflowEnabled(workflow.id),
                  (try? VoiceWorkflowOperationalValidator.validateMicrophone(
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

    enum AppTab: Hashable, CaseIterable {
        case dictate, history, notes, settings
    }

    @StateObject private var dictationViewModel = DictationViewModel()
    @State private var selectedTab: AppTab = .dictate
    @State private var pendingConfigImport: PendingConfigImport?
    @State private var configImportError: String?
    @State private var keyboardReadyError: String?
    @State private var noteRecordingRequest: NoteRecordingDeepLinkRequest?
    @State private var handledDeepLinkIDs: Set<UUID> = []
    private let modelContainer: ModelContainer
    private let noteService: NoteService
    @StateObject private var noteViewModel: NoteViewModel

    private struct PendingConfigImport: Identifiable {
        let id = UUID()
        let data: Data
        let summary: ScenarioImportSummary
        let consentProfiles: [ModelProfile]
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
            DictationView(
                viewModel: dictationViewModel,
                onOpenHistory: { selectedTab = .history }
            )
                .tabItem {
                    Label("Dictate", systemImage: "mic.fill")
                }
                .tag(AppTab.dictate)

            HistoryView(dictationViewModel: dictationViewModel)
                .tabItem {
                    Label("History", systemImage: "clock.fill")
                }
                .tag(AppTab.history)

            NotesView(
                noteService: noteService,
                noteViewModel: noteViewModel,
                recordingRequest: noteRecordingRequest
            )
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
            drainPendingDeepLinks()
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
            let request = (notification.userInfo?["request"] as? DictationDeepLinkRequest)
                ?? DictationDeepLinkRequest(
                    modeID: notification.userInfo?["mode"] as? String,
                    destinationID: notification.userInfo?["destination"] as? String
                )
            handleDictationDeepLink(request)
            DeepLinkRouter.acknowledge(request.id)
        }
        // fonos://note — the root owns the event so a cold-start notification
        // cannot be lost between the TabView and the Notes NavigationStack.
        .onReceive(NotificationCenter.default.publisher(for: .fonosOpenNotes)) { notification in
            let request = (notification.userInfo?["request"] as? NoteRecordingDeepLinkRequest)
                ?? NoteRecordingDeepLinkRequest(
                    notebookID: notification.userInfo?["notebookId"] as? String
                )
            handleNoteDeepLink(request)
            DeepLinkRouter.acknowledge(request.id)
        }
        // fonos://config?d=… — a shared config bundle (e.g. scanned QR). Decode
        // and show a preview; never apply untrusted input silently.
        .onReceive(NotificationCenter.default.publisher(for: .fonosImportConfig)) { notification in
            let request = notification.userInfo?["request"] as? ConfigImportDeepLinkRequest
            let payload = request?.payload ?? notification.userInfo?["payload"] as? String
            if let payload { handleConfigDeepLink(payload, id: request?.id ?? UUID()) }
            if let request { DeepLinkRouter.acknowledge(request.id) }
        }
        // fonos://keyboard-ready — the Fonos keyboard's mic was tapped while
        // Ready was off. Opening the link is the explicit user action.
        .onReceive(NotificationCenter.default.publisher(for: .fonosStartKeyboardReady)) { notification in
            let request = (notification.userInfo?["request"] as? KeyboardReadyDeepLinkRequest)
                ?? KeyboardReadyDeepLinkRequest()
            handleKeyboardReadyDeepLink(request)
            DeepLinkRouter.acknowledge(request.id)
        }
        .alert(
            "Keyboard Ready Couldn’t Start",
            isPresented: Binding(
                get: { keyboardReadyError != nil },
                set: { if !$0 { keyboardReadyError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { keyboardReadyError = nil }
        } message: {
            Text(keyboardReadyError ?? "")
        }
        .sheet(item: $pendingConfigImport) { pending in
            ConfigImportPreviewView(
                summary: pending.summary,
                consentProfiles: pending.consentProfiles,
                onImport: { allowed in
                    applyImportedConfig(pending.data, granting: allowed)
                },
                onCancel: {
                    configImportError = nil
                    pendingConfigImport = nil
                }
            )
            .alert(
                "Config Import Failed",
                isPresented: Binding(
                    get: { configImportError != nil && pendingConfigImport != nil },
                    set: { if !$0 { configImportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { configImportError = nil }
            } message: {
                Text(configImportError ?? "")
            }
        }
        .alert(
            "Config Import Failed",
            isPresented: Binding(
                get: { configImportError != nil && pendingConfigImport == nil },
                set: { if !$0 { configImportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { configImportError = nil }
        } message: {
            Text(configImportError ?? "")
        }
    }

    /// Apply an imported config bundle to the live config, Notes VM, and storage.
    private func applyImportedConfig(_ data: Data, granting allowedProfiles: [ModelProfile]) {
        do {
            let (newConfig, _) = try ScenarioImporter.apply(
                data: data,
                to: dictationViewModel.config,
                vocabStore: VocabStore()
            )
            allowedProfiles.forEach { RemoteAIConsentStore.grant(for: $0) }
            dictationViewModel.config = newConfig
            noteViewModel.config = newConfig
            AppConfigStorage.save(newConfig)
            pendingConfigImport = nil
            selectedTab = .dictate
        } catch {
            // Keep the preview open so the user can retry after correcting a
            // Keychain or validation failure.
            configImportError = error.localizedDescription
        }
    }

    private func handleDictationDeepLink(_ request: DictationDeepLinkRequest) {
        guard handledDeepLinkIDs.insert(request.id).inserted else { return }
        selectedTab = .dictate
        dictationViewModel.startRecording(from: request)
    }

    private func handleNoteDeepLink(_ request: NoteRecordingDeepLinkRequest) {
        guard handledDeepLinkIDs.insert(request.id).inserted else { return }
        selectedTab = .notes
        noteRecordingRequest = request
    }

    private func handleKeyboardReadyDeepLink(_ request: KeyboardReadyDeepLinkRequest) {
        guard handledDeepLinkIDs.insert(request.id).inserted else { return }
        Task { @MainActor in
            do {
                _ = try await BackgroundRecordingService.shared.enableKeyboardReadySession()
            } catch {
                keyboardReadyError = error.localizedDescription
            }
        }
    }

    private func handleConfigDeepLink(_ payload: String, id: UUID) {
        guard handledDeepLinkIDs.insert(id).inserted else { return }
        do {
            let data = try ConfigBundleCodec.decode(payload)
            let summary = try ScenarioImporter.preview(data: data)
            let consentProfiles = ScenarioImporter.remoteProfiles(data: data)
                .filter { !RemoteAIConsentStore.isAuthorized(for: $0) }
            pendingConfigImport = PendingConfigImport(
                data: data,
                summary: summary,
                consentProfiles: consentProfiles
            )
        } catch {
            configImportError = error.localizedDescription
        }
    }

    /// Replays URLs received while SwiftUI was still constructing ContentView.
    /// Requests handled live have already been acknowledged and are absent.
    private func drainPendingDeepLinks() {
        for request in DeepLinkRouter.takePendingRequests() {
            switch request {
            case .dictation(let value):
                handleDictationDeepLink(value)
            case .noteRecording(let value):
                handleNoteDeepLink(value)
            case .configImport(let value):
                handleConfigDeepLink(value.payload, id: value.id)
            case .keyboardReady(let value):
                handleKeyboardReadyDeepLink(value)
            }
        }
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
        let seededConfig = seedConfig()
        seedHistoryIfNeeded(in: context)
        seedNotesIfNeeded(in: context)
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
        WorkflowMigration.migrate(&seeded)
        seeded.activeVoiceWorkflowID = "wf.voice.polish"
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
