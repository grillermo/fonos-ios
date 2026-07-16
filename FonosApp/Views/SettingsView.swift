import SwiftUI

// MARK: - Settings View

/// Full settings screen with tabbed interface: Models | Modes | General.
struct SettingsView: View {

    // MARK: - Config state (shared with DictationViewModel via ContentView binding)

    @Binding var config: AppConfig

    // MARK: - Tab state

    enum SettingsTab {
        case models, modes, vocab, general
    }

    @State private var selectedTab: SettingsTab = .models

    // MARK: - Colors

    private let bg = Color(hex: "#1a1917")
    private let cardBg = Color.white.opacity(0.02)
    private let cardBorder = Color.white.opacity(0.04)
    private let separator = Color.white.opacity(0.04)
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let amber = Color(hex: "#fbbf24")

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Tab bar
                    tabBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    Divider()
                        .background(separator)

                    // Tab content
                    tabContent
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: config) { _, _ in
            saveConfig()
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "Models", tab: .models)
            tabButton(title: "Modes", tab: .modes)
            tabButton(title: "Vocab", tab: .vocab)
            tabButton(title: "General", tab: .general)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func tabButton(title: String, tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedTab = tab
            }
        } label: {
            Text(LocalizedStringKey(title))
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? Color(hex: "#1a1917") : textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? amber : Color.clear)
                        .shadow(
                            color: isSelected ? amber.opacity(0.3) : .clear,
                            radius: 4,
                            x: 0,
                            y: 2
                        )
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .models:
            ModelsTab(config: $config)
        case .modes:
            ModesTab(config: $config)
        case .vocab:
            VocabTab()
        case .general:
            generalTab
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        List {
            keyboardReadySection
            privacySection
            doctorSection
            dictationSection
            recordingSection
            destinationsSection
            historySection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Keyboard Ready Section

    private var keyboardReadySection: some View {
        Section {
            KeyboardReadyControl()
                .listRowBackground(cardBg)
        } header: {
            sectionHeader("Keyboard Dictation")
        } footer: {
            Text(
                """
                A custom iOS keyboard cannot open the microphone itself. \
                During a Keyboard Ready session, Fonos keeps microphone input active in the background but discards idle audio; \
                it retains audio only after you tap the Fonos keyboard microphone.
                """
            )
                .font(.system(size: 12))
                .foregroundColor(textDim)
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        Section {
            NavigationLink {
                PrivacySettingsView(config: config)
            } label: {
                Label {
                    Text("Privacy & Data Sharing")
                        .foregroundColor(textPrimary)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .foregroundColor(amber)
                }
            }
            .listRowBackground(cardBg)
        } footer: {
            Text("Review the privacy policy and withdraw permission for configured AI endpoints.")
                .font(.system(size: 12))
                .foregroundColor(textDim)
        }
    }

    // MARK: - Setup Doctor Section

    private var doctorSection: some View {
        Section {
            NavigationLink {
                SetupDoctorView(config: config)
            } label: {
                Label {
                    Text("Setup Doctor")
                        .foregroundColor(textPrimary)
                } icon: {
                    Image(systemName: "stethoscope")
                        .foregroundColor(amber)
                }
            }
            .listRowBackground(cardBg)
        } footer: {
            Text("Check permissions, keyboard setup, endpoints, and configuration in one place.")
                .font(.system(size: 12))
                .foregroundColor(textDim)
        }
    }

    // MARK: - Dictation Section

    private var dictationSection: some View {
        Section {
            Picker("Default Recipe", selection: activeWorkflowBinding) {
                ForEach(voiceWorkflows, id: \.id) { workflow in
                    Text(workflow.name)
                        .tag(workflow.id)
                        .disabled(!isWorkflowRunnable(workflow))
                }
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)

            // STT Language
            Picker("STT Language", selection: sttLanguageBinding) {
                Text("Auto-detect").tag("auto")
                Section("Common") {
                    Text("English").tag("en")
                    Text("中文 (Chinese)").tag("zh")
                    Text("日本語 (Japanese)").tag("ja")
                    Text("한국어 (Korean)").tag("ko")
                    Text("Español (Spanish)").tag("es")
                    Text("Français (French)").tag("fr")
                    Text("Deutsch (German)").tag("de")
                    Text("Português (Portuguese)").tag("pt")
                    Text("Italiano (Italian)").tag("it")
                    Text("Русский (Russian)").tag("ru")
                    Text("العربية (Arabic)").tag("ar")
                    Text("हिन्दी (Hindi)").tag("hi")
                    Text("ภาษาไทย (Thai)").tag("th")
                    Text("Tiếng Việt (Vietnamese)").tag("vi")
                    Text("Bahasa Indonesia").tag("id")
                    Text("Türkçe (Turkish)").tag("tr")
                    Text("Nederlands (Dutch)").tag("nl")
                    Text("Polski (Polish)").tag("pl")
                }
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)

        } header: {
            sectionHeader("Dictation")
        } footer: {
            Text(
                """
                Default Recipe is used when dictation starts. \
                STT Language updates the default transcription step. \
                Edit a recipe to change its AI prompt or output language.
                """
            )
                .foregroundColor(textDim)
                .font(.system(size: 12))
        }
    }

    private var voiceWorkflows: [WorkflowDefinition] {
        let catalog = config.workflowCatalog
        return catalog.workflows.filter {
            catalog.widget(id: $0.source)?.typeTag == "microphone"
        }
    }

    private var activeWorkflowBinding: Binding<String> {
        Binding(
            get: { config.activeVoiceWorkflowID },
            set: { workflowID in
                guard let workflow = config.workflowCatalog.workflow(id: workflowID),
                      (try? VoiceWorkflowOperationalValidator.validateMicrophone(
                        definition: workflow,
                        catalog: config.workflowCatalog,
                        config: config
                      )) != nil else { return }
                config.activeVoiceWorkflowID = workflowID
            }
        )
    }

    private func isWorkflowRunnable(_ workflow: WorkflowDefinition) -> Bool {
        (try? VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: workflow,
            catalog: config.workflowCatalog,
            config: config
        )) != nil
    }

    private var sttLanguageBinding: Binding<String> {
        Binding(
            get: { config.sttLanguage },
            set: { language in
                config.sttLanguage = language
                synchronizeDefaultSTTLanguage(language)
            }
        )
    }

    private func synchronizeDefaultSTTLanguage(_ language: String) {
        if let index = config.widgets.firstIndex(where: { $0.id == "stt.default" }) {
            // A non-builtin overlay may have been imported from desktop and is
            // recipe-owned; do not silently rewrite it from a legacy setting.
            guard config.widgets[index].builtin,
                  case .object(var props) = config.widgets[index].props else { return }
            props["language"] = .string(language)
            config.widgets[index].props = .object(props)
            return
        }

        guard var widget = config.workflowCatalog.widget(id: "stt.default"),
              widget.builtin,
              case .object(var props) = widget.props else { return }
        props["language"] = .string(language)
        widget.props = .object(props)
        config.widgets.append(widget)
    }

    // MARK: - Recording Section

    private var recordingSection: some View {
        Section {
            Picker("Active Recipe Capture", selection: activeCaptureBinding) {
                Text("Tap to Record").tag(RecordMode.tap)
                Text("Hold to Record").tag(RecordMode.hold)
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)

            let autoSendEnabled = Binding<Bool>(
                get: { !config.autoSendDestination.isEmpty },
                set: { enabled in
                    if !enabled {
                        config.autoSendDestination = ""
                    } else if config.autoSendDestination.isEmpty,
                              let first = config.destinations.first {
                        config.autoSendDestination = first.id
                    }
                }
            )

            Toggle("Auto-send After Dictation", isOn: autoSendEnabled)
                .tint(amber)
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)
                .listRowSeparatorTint(separator)

            if !config.autoSendDestination.isEmpty {
                Picker("Destination", selection: $config.autoSendDestination) {
                    ForEach(config.destinations, id: \.id) { destination in
                        Text(destinationLabel(destination)).tag(destination.id)
                    }
                }
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)
                .listRowSeparatorTint(separator)
            }
        } header: {
            sectionHeader("Recording")
        } footer: {
            Text(
                """
                Capture is stored in the selected recipe. \
                The keyboard adapts microphone recipes to its tap control. \
                Auto-send is added as a traced iOS output for each run.
                """
            )
                .foregroundColor(textDim)
                .font(.system(size: 12))
        }
    }

    private var activeCaptureBinding: Binding<RecordMode> {
        Binding(
            get: {
                guard let workflow = config.activeVoiceWorkflow,
                      let source = config.workflowCatalog.widget(id: workflow.source) else {
                    return config.recordMode
                }
                return source.props["capture"]?.stringValue == "toggle" ? .tap : .hold
            },
            set: { mode in
                config.recordMode = mode // Codable compatibility mirror.
                guard var workflow = config.activeVoiceWorkflow else { return }
                workflow.source = mode == .hold ? "src.mic-hold" : "src.mic-toggle"
                if let index = config.workflows.firstIndex(where: { $0.id == workflow.id }) {
                    config.workflows[index] = workflow
                } else {
                    config.workflows.append(workflow)
                }
            }
        )
    }

    // MARK: - Destinations Section

    private var destinationsSection: some View {
        DestinationsSection(config: $config)
    }

    // MARK: - History Section

    private var historySection: some View {
        Section {
            Picker("Retention Period", selection: $config.historyRetentionDays) {
                Text("7 Days").tag(7)
                Text("30 Days").tag(30)
                Text("90 Days").tag(90)
                Text("Forever").tag(0)
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)
        } header: {
            sectionHeader("History")
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(textDim)
            .textCase(nil)
    }

    // MARK: - Helpers

    private func destinationLabel(_ destination: AnyTextDestination) -> String {
        switch destination.id {
        case "clipboard": return "Clipboard"
        case "messages":  return "Messages"
        case "url_scheme": return "URL Scheme"
        default:           return destination.id.capitalized
        }
    }

    // MARK: - Persistence

    private func saveConfig() {
        AppConfigStorage.save(config)
    }
}

// MARK: - Add Destination Sheet

/// Sheet for adding a new destination.
struct AddDestinationSheet: View {
    @Binding var config: AppConfig
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: DestinationType = .urlScheme
    @State private var urlTemplate: String = ""

    private let amber = Color(hex: "#fbbf24")
    private let bg = Color(hex: "#1a1917")
    private let textPrimary = Color(hex: "#fafaf9")
    private let cardBg = Color.white.opacity(0.06)

    enum DestinationType: String, CaseIterable, Identifiable {
        case messages = "Messages"
        case urlScheme = "URL Scheme"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()

                Form {
                    Section {
                        Picker("Type", selection: $selectedType) {
                            ForEach(DestinationType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .foregroundColor(textPrimary)
                        .listRowBackground(cardBg)
                    } header: {
                        Text("DESTINATION TYPE")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(textPrimary.opacity(0.5))
                            .textCase(nil)
                    }

                    if selectedType == .urlScheme {
                        Section {
                            TextField("e.g. myapp://send?text={text}", text: $urlTemplate)
                                .foregroundColor(textPrimary)
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .listRowBackground(cardBg)
                        } header: {
                            Text("URL TEMPLATE")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(textPrimary.opacity(0.5))
                                .textCase(nil)
                        } footer: {
                            Text("Use {text} as a placeholder for the dictated text.")
                                .foregroundColor(textPrimary.opacity(0.4))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(amber)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addDestination()
                        dismiss()
                    }
                    .foregroundColor(amber)
                    .disabled(!canAdd)
                }
            }
        }
    }

    private var canAdd: Bool {
        switch selectedType {
        case .messages:  return true
        case .urlScheme: return !urlTemplate.isEmpty
        }
    }

    private func addDestination() {
        switch selectedType {
        case .messages:
            let dest = AnyTextDestination(MessagesDestination())
            if !config.destinations.contains(where: { $0.id == dest.id }) {
                config.destinations.append(dest)
            }
        case .urlScheme:
            let dest = AnyTextDestination(URLSchemeDestination(template: urlTemplate))
            config.destinations.append(dest)
        }
    }
}

#Preview {
    SettingsView(config: .constant(AppConfig()))
}
