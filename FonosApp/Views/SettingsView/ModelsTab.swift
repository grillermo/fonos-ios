import SwiftUI
import UniformTypeIdentifiers

// MARK: - Models Tab

/// Settings tab for managing AI model profiles.
/// Provides default service assignment and full CRUD for model profiles.
struct ModelsTab: View {
    @Binding var config: AppConfig

    @State private var showScenarioImporter = false
    @State private var pendingScenarioImport: PendingScenarioImport?
    @State private var scenarioSummary: ScenarioImportSummary?
    @State private var scenarioError: String?
    @State private var showAddModel = false
    @State private var editingProfile: ModelProfile?
    @State private var showProbe = false
    @State private var probeURL = ""
    @State private var probeKey = ""
    @State private var probeProvider = "omlx"
    @State private var probeResult: ModelProbeService.ProbeResult?
    @State private var probing = false
    @State private var probeError: String?
    @State private var reviewingConsentProfile: ModelProfile?
    @State private var consentRevision = 0

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let cardBg = Color.white.opacity(0.02)
    private let cardBorder = Color.white.opacity(0.04)
    private let separator = Color.white.opacity(0.04)

    private struct PendingScenarioImport: Identifiable {
        let id = UUID()
        let data: Data
        let summary: ScenarioImportSummary
    }

    var body: some View {
        List {
            defaultServicesSection
            registeredModelsSection
            remoteAIConsentSection
            scenarioImportSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .fileImporter(isPresented: $showScenarioImporter, allowedContentTypes: [.json]) { result in
            importScenario(result)
        }
        .sheet(item: $pendingScenarioImport) { pending in
            ConfigImportPreviewView(
                summary: pending.summary,
                onImport: {
                    applyScenario(pending.data)
                    pendingScenarioImport = nil
                },
                onCancel: { pendingScenarioImport = nil }
            )
        }
        .alert("Scenario imported", isPresented: .init(
            get: { scenarioSummary != nil },
            set: { if !$0 { scenarioSummary = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scenarioSummaryText)
        }
        .alert("Import failed", isPresented: .init(
            get: { scenarioError != nil },
            set: { if !$0 { scenarioError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(scenarioError ?? "")
        }
        .sheet(isPresented: $showAddModel) {
            ModelProfileForm(onSave: { profile in
                config.modelProfiles.append(profile)
            })
        }
        .sheet(isPresented: $showProbe) {
            ProbeSheet(
                probeURL: $probeURL,
                probeKey: $probeKey,
                probeProvider: $probeProvider,
                probing: $probing,
                probeError: $probeError,
                probeResult: $probeResult,
                onAddModels: { models, apiKey in
                    for model in models {
                        let profileID = "\(model.provider)-\(Int(Date().timeIntervalSince1970))-\(abs(model.id.hashValue) % 10000)"
                        let profile = ModelProfile(
                            id: profileID,
                            name: model.name,
                            provider: model.provider,
                            modelID: model.id,
                            baseURL: model.baseURL,  // URL from the model itself — guaranteed correct
                            capabilities: model.capabilities,
                            sttAPI: model.capabilities.contains("stt") && model.provider == "openrouter"
                                ? "chat"
                                : nil
                        )
                        print("✅ Adding model: \(profile.name), baseURL=\(profile.baseURL ?? "nil"), caps=\(profile.capabilities)")
                        config.modelProfiles.append(profile)
                        if !apiKey.isEmpty {
                            try? KeychainStore(service: "com.fonos.models").set(apiKey, forKey: profileID)
                        }
                    }
                }
            )
        }
        .sheet(item: $editingProfile) { profile in
            ModelProfileForm(
                initialProfile: profile,
                onSave: { updated in
                    if let idx = config.modelProfiles.firstIndex(where: { $0.id == profile.id }) {
                        config.modelProfiles[idx] = updated
                        revokeUnusedConsent(afterReplacing: profile, with: updated)
                    }
                }
            )
        }
        .alert(
            "Allow Remote AI Processing?",
            isPresented: Binding(
                get: { reviewingConsentProfile != nil },
                set: { if !$0 { reviewingConsentProfile = nil } }
            ),
            presenting: reviewingConsentProfile
        ) { profile in
            Button("Not Now", role: .cancel) {}
            Button("Allow") {
                RemoteAIConsentStore.grant(for: profile)
                consentRevision += 1
            }
        } message: { profile in
            Text(RemoteAIConsentStore.disclosure(for: profile))
        }
    }
}

extension ModelsTab {

    // MARK: - Scenario Import (P1-2)

    private var scenarioImportSection: some View {
        Section {
            NavigationLink {
                ConfigSetsView(config: $config)
            } label: {
                Label("Config Sets & QR Sharing", systemImage: "qrcode")
                    .foregroundColor(amber)
            }
            .listRowBackground(cardBg)

            Button {
                showScenarioImporter = true
            } label: {
                Label("Import Scenario File", systemImage: "square.and.arrow.down")
                    .foregroundColor(amber)
            }
            .listRowBackground(cardBg)
        } footer: {
            // Keep this as one literal so String Catalog extraction preserves the exact key.
            // swiftlint:disable:next line_length
            Text("Save your setup as a named config set and share it as a QR code (API keys stripped), or import one by scanning. “Import Scenario File” loads a scenario exported from Fonos desktop.")
                .font(.system(size: 12))
                .foregroundColor(textDim)
        }
    }

    private var scenarioSummaryText: String {
        guard let s = scenarioSummary else { return "" }
        var lines: [String] = []
        if !s.name.isEmpty { lines.append("“\(s.name)”") }
        lines.append("\(s.importedProfiles) model profile(s) imported")
        if s.vocabBooksImported > 0 { lines.append("\(s.vocabBooksImported) vocab book(s) imported") }
        if s.dictationApplied { lines.append("Dictation defaults applied") }
        if s.noRunnableWorkflow {
            lines.append("No runnable microphone recipe remains; active recipe cleared")
        } else if s.activeWorkflowAdjusted {
            let label = s.selectedWorkflowName.isEmpty
                ? s.selectedWorkflowID
                : "\(s.selectedWorkflowName) (\(s.selectedWorkflowID))"
            lines.append("Active recipe adjusted to \(label)")
        }
        if !s.skippedSections.isEmpty {
            lines.append("Skipped (not applicable on iOS): \(s.skippedSections.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func importScenario(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pendingScenarioImport = PendingScenarioImport(
                data: data,
                summary: try ScenarioImporter.preview(data: data)
            )
        } catch {
            scenarioError = error.localizedDescription
        }
    }

    private func applyScenario(_ data: Data) {
        do {
            let (newConfig, summary) = try ScenarioImporter.apply(
                data: data,
                to: config,
                vocabStore: VocabStore()
            )
            config = newConfig
            scenarioSummary = summary
        } catch {
            scenarioError = error.localizedDescription
        }
    }

    // MARK: - Default Services Section

    private var defaultServicesSection: some View {
        Section {
            // STT default
            Picker(selection: $config.sttProfile) {
                Text("Not configured").tag("")
                ForEach(sttModels) { profile in
                    Text(profile.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .tag(profile.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundColor(amber)
                        .frame(width: 22)
                    Text("STT Model")
                        .foregroundColor(textPrimary)
                }
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)

            // LLM default
            Picker(selection: $config.llmProfile) {
                Text("Not configured").tag("")
                ForEach(llmModels) { profile in
                    Text(profile.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .tag(profile.id)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .foregroundColor(green)
                        .frame(width: 22)
                    Text("LLM Model")
                        .foregroundColor(textPrimary)
                }
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)
        } header: {
            sectionHeader("Default Services")
        }
    }

    // MARK: - Registered Models Section

    private var registeredModelsSection: some View {
        Section {
            if config.modelProfiles.isEmpty {
                Text("No models registered")
                    .foregroundColor(textDim)
                    .font(.system(size: 14))
                    .listRowBackground(cardBg)
                    .listRowSeparatorTint(separator)
            } else {
                ForEach(config.modelProfiles, id: \.id) { profile in
                    ModelProfileRow(
                        profile: profile,
                        isDefaultSTT: config.sttProfile == profile.id,
                        isDefaultLLM: config.llmProfile == profile.id,
                        amber: amber,
                        green: green,
                        textPrimary: textPrimary,
                        textDim: textDim,
                        cardBg: cardBg,
                        separator: separator,
                        onTap: { editingProfile = profile }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteProfile(id: profile.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            // Add Model button
            Button {
                showAddModel = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(amber)
                    Text("Add Model Manually")
                        .foregroundColor(amber)
                }
            }
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)

            // Probe button
            Button {
                showProbe = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(green)
                    Text("Probe Endpoint")
                        .foregroundColor(green)
                    Spacer()
                    Text("Auto-detect models")
                        .font(.system(size: 11))
                        .foregroundColor(textDim)
                }
            }
            .listRowBackground(cardBg)
            .listRowSeparatorTint(separator)
        } header: {
            sectionHeader("Registered Models")
        }
    }

    private var remoteAIConsentSection: some View {
        Section {
            ForEach(profilesBlockedByTransport) { profile in
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("HTTPS required for \(profile.name)")
                            .foregroundColor(textPrimary)
                        Text(profile.effectiveBaseURL)
                            .font(.caption)
                            .foregroundColor(textDim)
                    }
                }
                .listRowBackground(cardBg)
            }

            if profilesNeedingConsent.isEmpty && profilesBlockedByTransport.isEmpty {
                Label("Configured endpoints are ready", systemImage: "checkmark.shield.fill")
                    .foregroundColor(green)
                    .listRowBackground(cardBg)
            } else if !profilesNeedingConsent.isEmpty {
                ForEach(profilesNeedingConsent) { profile in
                    Button {
                        reviewingConsentProfile = profile
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "hand.raised.fill")
                                .foregroundColor(amber)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Review \(profile.name)")
                                    .foregroundColor(textPrimary)
                                if let identity = RemoteAIConsentStore.identity(for: profile) {
                                    Text("\(identity.providerDisplayName) · \(identity.origin)")
                                        .font(.caption)
                                        .foregroundColor(textDim)
                                }
                            }
                            Spacer()
                            Text("Required")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(amber)
                        }
                    }
                    .listRowBackground(cardBg)
                }
            }
        } header: {
            sectionHeader("Remote AI Data Sharing")
        } footer: {
            // Keep this as one literal so String Catalog extraction preserves the exact key.
            // swiftlint:disable:next line_length
            Text("Fonos blocks voice and text requests to a configured endpoint until you review the recipient and allow that destination. Permissions can be withdrawn under General → Privacy & Data Sharing.")
                .font(.system(size: 12))
                .foregroundColor(textDim)
        }
    }

    // MARK: - Helpers

    private var sttModels: [ModelProfile] {
        config.modelProfiles.filter(\.hasSTT)
    }

    private var llmModels: [ModelProfile] {
        config.modelProfiles.filter(\.hasLLM)
    }

    private var profilesNeedingConsent: [ModelProfile] {
        _ = consentRevision
        return config.modelProfiles.filter {
            RemoteAITransportPolicy.allows($0.effectiveBaseURL)
                && !RemoteAIConsentStore.isAuthorized(for: $0)
        }
    }

    private var profilesBlockedByTransport: [ModelProfile] {
        config.modelProfiles.filter {
            !RemoteAITransportPolicy.allows($0.effectiveBaseURL)
        }
    }

    private func deleteProfile(id: String) {
        let deleted = config.modelProfiles.first(where: { $0.id == id })
        try? KeychainStore(service: "com.fonos.models").delete(id)
        config.removeModelProfile(id: id)
        if let deleted,
           let deletedIdentity = RemoteAIConsentStore.identity(for: deleted),
           !config.modelProfiles.contains(where: {
               RemoteAIConsentStore.identity(for: $0) == deletedIdentity
           }) {
            RemoteAIConsentStore.revoke(for: deleted)
            consentRevision += 1
        }
    }

    private func revokeUnusedConsent(afterReplacing old: ModelProfile, with updated: ModelProfile) {
        guard let oldIdentity = RemoteAIConsentStore.identity(for: old),
              oldIdentity != RemoteAIConsentStore.identity(for: updated),
              !config.modelProfiles.contains(where: {
                  $0.id != updated.id && RemoteAIConsentStore.identity(for: $0) == oldIdentity
              }) else { return }
        RemoteAIConsentStore.revoke(for: old)
        consentRevision += 1
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(textDim)
            .textCase(nil)
    }
}

// MARK: - Model Profile Row

private struct ModelProfileRow: View {
    let profile: ModelProfile
    let isDefaultSTT: Bool
    let isDefaultLLM: Bool
    let amber: Color
    let green: Color
    let textPrimary: Color
    let textDim: Color
    let cardBg: Color
    let separator: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Provider icon
                providerIcon(for: profile.provider)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .foregroundColor(textPrimary)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.tail)

                    HStack(spacing: 6) {
                        Text("\(providerDisplayName(profile.provider)) · \(profile.modelID)")
                            .font(.system(size: 12))
                            .foregroundColor(textDim)
                    }

                    // Capability badges + default badges
                    HStack(spacing: 6) {
                        if profile.hasSTT {
                            badgeView("STT", color: amber)
                        }
                        if profile.hasLLM {
                            badgeView("LLM", color: green)
                        }
                        if isDefaultSTT {
                            badgeView("Default STT", color: amber.opacity(0.6))
                        }
                        if isDefaultLLM {
                            badgeView("Default LLM", color: green.opacity(0.6))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(textDim)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(PlainButtonStyle())
        .listRowBackground(cardBg)
        .listRowSeparatorTint(separator)
    }

    private func badgeView(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.12))
            )
    }

    private func providerIcon(for provider: String) -> some View {
        let (icon, color): (String, Color) = {
            switch provider {
            case "openai":    return ("brain", amber)
            case "anthropic": return ("sparkle", Color(hex: "#c084fc"))
            case "google":    return ("magnifyingglass.circle", Color(hex: "#60a5fa"))
            case "ollama":    return ("server.rack", green)
            case "lmstudio":  return ("laptopcomputer", green)
            case "omlx":      return ("apple.terminal", Color(hex: "#60a5fa"))
            default:          return ("network", textDim)
            }
        }()
        return Image(systemName: icon)
            .foregroundColor(color)
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider {
        case "openai":    return "OpenAI"
        case "openrouter": return "OpenRouter"
        case "anthropic": return "Anthropic"
        case "google":    return "Google"
        case "ollama":    return "Ollama"
        case "lmstudio":  return "LM Studio"
        case "omlx":      return "OMLX"
        case "custom":    return "Custom"
        default:          return provider.capitalized
        }
    }
}

// MARK: - Model Profile Form

private struct ModelProviderOption {
    let id: String
    let label: String
    let icon: String
}

/// Sheet for adding or editing a model profile.
struct ModelProfileForm: View {
    var initialProfile: ModelProfile?
    let onSave: (ModelProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    // Provider selection
    @State private var selectedProvider: String = "openai"

    // Form fields
    @State private var name: String = ""
    @State private var modelID: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var hasStt: Bool = false
    @State private var hasLlm: Bool = true
    @State private var sttAPI: String = "whisper"
    @State private var pendingConsentProfile: ModelProfile?

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let bg = Color(hex: "#1a1917")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let cardBg = Color.white.opacity(0.06)

    private let providers: [ModelProviderOption] = [
        ModelProviderOption(id: "openai", label: "OpenAI", icon: "brain"),
        ModelProviderOption(id: "openrouter", label: "OpenRouter", icon: "arrow.triangle.branch"),
        ModelProviderOption(id: "anthropic", label: "Anthropic", icon: "sparkle"),
        ModelProviderOption(id: "google", label: "Google", icon: "magnifyingglass.circle"),
        ModelProviderOption(id: "ollama", label: "Ollama", icon: "server.rack"),
        ModelProviderOption(id: "lmstudio", label: "LM Studio", icon: "laptopcomputer"),
        ModelProviderOption(id: "omlx", label: "OMLX", icon: "apple.terminal"),
        ModelProviderOption(id: "custom", label: "Custom", icon: "network")
    ]

    private let keychainModels = KeychainStore(service: "com.fonos.models")

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()

                Form {
                    // Provider Picker (grid)
                    providerPickerSection

                    // Form fields
                    fieldsSection

                    // Capabilities
                    capabilitiesSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(initialProfile == nil ? "Add Model" : "Edit Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(amber)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        requestSave()
                    }
                    .foregroundColor(amber)
                    .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: populateFromInitial)
        .onChange(of: selectedProvider) { _, _ in
            // Only reset URL to default when adding a NEW model (not editing existing)
            // When editing, the URL was already set from the profile in populateFromInitial
            if initialProfile == nil {
                baseURL = defaultBaseURL(for: selectedProvider)
            }
        }
        .alert(
            "Allow Remote AI Processing?",
            isPresented: Binding(
                get: { pendingConsentProfile != nil },
                set: { if !$0 { pendingConsentProfile = nil } }
            ),
            presenting: pendingConsentProfile
        ) { profile in
            Button("Not Now", role: .cancel) {}
            Button("Allow & Save") {
                RemoteAIConsentStore.grant(for: profile)
                commitSave(profile)
            }
        } message: { profile in
            Text(RemoteAIConsentStore.disclosure(for: profile))
        }
    }

    // MARK: - Provider Picker

    private var providerPickerSection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(providers, id: \.id) { provider in
                    ProviderButton(
                        label: provider.label,
                        icon: provider.icon,
                        isSelected: selectedProvider == provider.id,
                        amber: amber,
                        textPrimary: textPrimary,
                        textDim: textDim
                    ) {
                        selectedProvider = provider.id
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4))
        } header: {
            formHeader("Provider")
        }
    }

    // MARK: - Fields Section

    private var fieldsSection: some View {
        Section {
            TextField("Name", text: $name)
                .foregroundColor(textPrimary)
                .tint(amber)
                .listRowBackground(cardBg)

            TextField("Model ID", text: $modelID)
                .foregroundColor(textPrimary)
                .tint(amber)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .font(.system(size: 15, design: .monospaced))
                .listRowBackground(cardBg)

            SecureField("API Key (stored in Keychain)", text: $apiKey)
                .foregroundColor(textPrimary)
                .tint(amber)
                .listRowBackground(cardBg)

            TextField("Base URL", text: $baseURL)
                .foregroundColor(textPrimary)
                .tint(amber)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .listRowBackground(cardBg)
        } header: {
            formHeader("Configuration")
        }
    }

    // MARK: - Capabilities Section

    private var capabilitiesSection: some View {
        Section {
            Toggle("Speech-to-Text (STT)", isOn: $hasStt)
                .tint(amber)
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)

            if hasStt {
                Picker("STT API", selection: $sttAPI) {
                    Text("Whisper audio endpoint").tag("whisper")
                    Text("Chat with input_audio").tag("chat")
                }
                .pickerStyle(.navigationLink)
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)
            }

            Toggle("Language Model (LLM)", isOn: $hasLlm)
                .tint(green)
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)
        } header: {
            formHeader("Capabilities")
        } footer: {
            Text("Enable the capabilities this model supports.")
                .foregroundColor(textDim)
        }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !modelID.trimmingCharacters(in: .whitespaces).isEmpty &&
        (hasStt || hasLlm) &&
        RemoteAIEndpointIdentity(
            provider: selectedProvider,
            baseURL: baseURL.isEmpty ? defaultBaseURL(for: selectedProvider) : baseURL
        ) != nil &&
        RemoteAITransportPolicy.allows(
            baseURL.isEmpty ? defaultBaseURL(for: selectedProvider) : baseURL
        )
    }

    private func formHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(textDim)
            .textCase(nil)
    }

    private func defaultBaseURL(for provider: String) -> String {
        switch provider {
        case "openai":    return "https://api.openai.com"
        case "openrouter": return "https://openrouter.ai/api/v1"
        case "anthropic": return "https://api.anthropic.com"
        case "google":    return "https://generativelanguage.googleapis.com"
        case "ollama":    return "http://localhost:11434"
        case "lmstudio":  return "http://localhost:1234"
        case "omlx":      return "http://localhost:8000"
        default:          return ""
        }
    }

    private func populateFromInitial() {
        guard let profile = initialProfile else {
            baseURL = defaultBaseURL(for: selectedProvider)
            return
        }
        selectedProvider = profile.provider
        name = profile.name
        modelID = profile.modelID
        baseURL = profile.baseURL ?? defaultBaseURL(for: profile.provider)
        hasStt = profile.hasSTT
        hasLlm = profile.hasLLM
        sttAPI = profile.effectiveSTTAPI
        // Load API key from Keychain
        apiKey = (try? keychainModels.get(profile.id)) ?? ""
    }

    private func requestSave() {
        let profile = makeProfile()
        if RemoteAIConsentStore.isAuthorized(for: profile) {
            commitSave(profile)
        } else {
            pendingConsentProfile = profile
        }
    }

    private func makeProfile() -> ModelProfile {
        var capabilities: [String] = []
        if hasStt { capabilities.append("stt") }
        if hasLlm { capabilities.append("llm") }

        let profileID: String
        if let existing = initialProfile {
            profileID = existing.id
        } else {
            profileID = "\(selectedProvider)-\(Int(Date().timeIntervalSince1970))"
        }

        return ModelProfile(
            id: profileID,
            name: name.trimmingCharacters(in: .whitespaces),
            provider: selectedProvider,
            modelID: modelID.trimmingCharacters(in: .whitespaces),
            baseURL: baseURL.isEmpty ? nil : baseURL,
            capabilities: capabilities,
            sttAPI: hasStt ? sttAPI : nil
        )
    }

    private func commitSave(_ profile: ModelProfile) {
        // The credential remains in Keychain and is never placed in AppConfig
        // or the remote-AI consent record.
        if !apiKey.isEmpty {
            try? keychainModels.set(apiKey, forKey: profile.id)
        }
        onSave(profile)
        dismiss()
    }
}

// MARK: - Provider Button

private struct ProviderButton: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let amber: Color
    let textPrimary: Color
    let textDim: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Color(hex: "#1a1917") : textPrimary.opacity(0.7))
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Color(hex: "#1a1917") : textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? amber : Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                isSelected ? Color.clear : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(
                color: isSelected ? amber.opacity(0.3) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(PlainButtonStyle())
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - Probe Sheet

private struct ProbeProviderOption {
    let id: String
    let label: String
    let defaultURL: String
}

/// Sheet for probing an endpoint to discover available models.
private struct ProbeSheet: View {
    @Binding var probeURL: String
    @Binding var probeKey: String
    @Binding var probeProvider: String
    @Binding var probing: Bool
    @Binding var probeError: String?
    @Binding var probeResult: ModelProbeService.ProbeResult?
    let onAddModels: (_ models: [ModelProbeService.DiscoveredModel], _ apiKey: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedModels: Set<String> = []
    @State private var modelCapabilities: [String: Set<String>] = [:]  // modelID → user-chosen caps
    @State private var pendingConsentModels: [ModelProbeService.DiscoveredModel] = []

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let bg = Color(hex: "#1a1917")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)

    private let probeProviders: [ProbeProviderOption] = [
        ProbeProviderOption(id: "omlx", label: "OMLX", defaultURL: "http://localhost:8000"),
        ProbeProviderOption(id: "ollama", label: "Ollama", defaultURL: "http://localhost:11434"),
        ProbeProviderOption(id: "lmstudio", label: "LM Studio", defaultURL: "http://localhost:1234"),
        ProbeProviderOption(id: "openrouter", label: "OpenRouter", defaultURL: "https://openrouter.ai/api/v1"),
        ProbeProviderOption(id: "custom", label: "Custom", defaultURL: "")
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()

                Form {
                    // Provider quick-select
                    Section {
                        ForEach(probeProviders, id: \.id) { p in
                            Button {
                                probeProvider = p.id
                                probeURL = p.defaultURL
                            } label: {
                                HStack {
                                    Text(p.label)
                                        .foregroundColor(probeProvider == p.id ? amber : textPrimary)
                                    Spacer()
                                    if probeProvider == p.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(amber)
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.04))
                        }
                    } header: {
                        Text("PROVIDER").font(.system(size: 12, weight: .medium)).foregroundColor(textDim).textCase(nil)
                    }

                    // URL + Key
                    Section {
                        TextField("Endpoint URL", text: $probeURL)
                            .foregroundColor(textPrimary)
                            .tint(amber)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .listRowBackground(Color.white.opacity(0.06))

                        SecureField("API Key (optional)", text: $probeKey)
                            .foregroundColor(textPrimary)
                            .tint(amber)
                            .listRowBackground(Color.white.opacity(0.06))
                    } header: {
                        Text("ENDPOINT").font(.system(size: 12, weight: .medium)).foregroundColor(textDim).textCase(nil)
                    }

                    // Probe button
                    Section {
                        Button {
                            runProbe()
                        } label: {
                            HStack {
                                Spacer()
                                if probing {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("Probe")
                                }
                                Spacer()
                            }
                            .foregroundColor(.white)
                            .padding(.vertical, 4)
                        }
                        .disabled(probeURL.isEmpty || probing)
                        .listRowBackground(probeURL.isEmpty ? Color.gray.opacity(0.3) : amber)
                    }

                    // Error
                    if let error = probeError {
                        Section {
                            Text(error)
                                .foregroundColor(Color.red)
                                .font(.system(size: 13))
                                .listRowBackground(Color.red.opacity(0.08))
                        }
                    }

                    // Results
                    if let result = probeResult {
                        Section {
                            ForEach(result.models) { model in
                                VStack(alignment: .leading, spacing: 8) {
                                    // Top row: checkbox + name
                                    HStack(spacing: 12) {
                                        Button { toggleModel(model.id) } label: {
                                            Image(systemName: selectedModels.contains(model.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(selectedModels.contains(model.id) ? amber : textDim)
                                                .font(.system(size: 20))
                                        }
                                        .buttonStyle(.plain)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(model.name)
                                                .foregroundColor(textPrimary)
                                                .font(.system(size: 14, weight: .medium))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                            Text(model.id)
                                                .foregroundColor(textDim)
                                                .font(.system(size: 11, design: .monospaced))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }

                                    // Capability row: auto-detected badges OR user toggles
                                    if model.autoDetected {
                                        // API provided type — show as read-only badges
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.seal.fill")
                                                .font(.system(size: 9))
                                                .foregroundColor(green.opacity(0.5))
                                            ForEach(model.capabilities, id: \.self) { cap in
                                                capBadge(cap)
                                            }
                                        }
                                    } else {
                                        // No API type — user chooses capabilities
                                        HStack(spacing: 6) {
                                            Text("Type:")
                                                .font(.system(size: 11))
                                                .foregroundColor(textDim)
                                            capToggle("STT", cap: "stt", modelID: model.id, color: amber)
                                            capToggle("LLM", cap: "llm", modelID: model.id, color: green)
                                            capToggle("TTS", cap: "tts", modelID: model.id, color: Color(hex: "#c084fc"))
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color.white.opacity(0.04))
                            }
                        } header: {
                            HStack {
                                Text("DISCOVERED \(result.models.count) MODELS")
                                    .font(.system(size: 12, weight: .medium)).foregroundColor(green).textCase(nil)
                                Spacer()
                                Button {
                                    if selectedModels.count == result.models.count {
                                        selectedModels.removeAll()
                                    } else {
                                        selectedModels = Set(result.models.map(\.id))
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: selectedModels.count == result.models.count
                                              ? "checkmark.circle.fill" : "circle.dashed")
                                            .font(.system(size: 11))
                                        Text(selectedModels.count == result.models.count ? "Deselect All" : "Select All")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundColor(amber)
                                    .textCase(nil)
                                }
                            }
                        }

                        // Add selected — only models with at least one capability
                        Section {
                            Button {
                                let selected = result.models.filter { selectedModels.contains($0.id) }
                                // Apply user-selected capabilities
                                let resolved = selected.map { model -> ModelProbeService.DiscoveredModel in
                                    if model.autoDetected { return model }
                                    var m = model
                                    m.capabilities = Array(modelCapabilities[model.id, default: []])
                                    return m
                                }
                                // Filter out models with no capabilities chosen
                                let valid = resolved.filter { !$0.capabilities.isEmpty }
                                guard !valid.isEmpty else { return }
                                requestAdd(valid)
                            } label: {
                                let validCount = validModelCount(in: result)
                                HStack {
                                    Spacer()
                                    if validCount == 0 && !selectedModels.isEmpty {
                                        Text("Select type for each model first")
                                            .fontWeight(.medium)
                                    } else {
                                        Text("Add \(validCount) Model\(validCount == 1 ? "" : "s")")
                                            .fontWeight(.semibold)
                                    }
                                    Spacer()
                                }
                                .foregroundColor(.white)
                                .padding(.vertical, 4)
                            }
                            .disabled(validModelCount(in: result) == 0)
                            .listRowBackground(validModelCount(in: result) == 0 ? Color.gray.opacity(0.3) : green)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Probe Endpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(amber)
                }
            }
        }
        .onAppear {
            if probeURL.isEmpty {
                probeURL = probeProviders.first?.defaultURL ?? ""
            }
        }
        .alert(
            "Allow Remote AI Processing?",
            isPresented: Binding(
                get: { !pendingConsentModels.isEmpty },
                set: { if !$0 { pendingConsentModels = [] } }
            ),
            presenting: pendingConsentProfile
        ) { profile in
            Button("Not Now", role: .cancel) {}
            Button("Allow & Add") {
                RemoteAIConsentStore.grant(for: profile)
                let models = pendingConsentModels
                pendingConsentModels = []
                onAddModels(models, probeKey)
                dismiss()
            }
        } message: { profile in
            Text(RemoteAIConsentStore.disclosure(for: profile))
        }
    }

    private func capBadge(_ cap: String) -> some View {
        let color: Color = cap == "stt" ? amber : cap == "llm" ? green : Color(hex: "#c084fc")
        return Text(cap.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }

    private func capToggle(_ label: String, cap: String, modelID: String, color: Color) -> some View {
        let isOn = modelCapabilities[modelID, default: []].contains(cap)
        return Button {
            if isOn {
                modelCapabilities[modelID, default: []].remove(cap)
            } else {
                modelCapabilities[modelID, default: []].insert(cap)
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isOn ? .white : color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? color : color.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }

    /// Count models that are selected AND have at least one capability.
    private func validModelCount(in result: ModelProbeService.ProbeResult) -> Int {
        result.models.filter { model in
            guard selectedModels.contains(model.id) else { return false }
            if model.autoDetected { return !model.capabilities.isEmpty }
            return !(modelCapabilities[model.id, default: []].isEmpty)
        }.count
    }

    private var pendingConsentProfile: ModelProfile? {
        guard let first = pendingConsentModels.first else { return nil }
        let capabilities = Set(pendingConsentModels.flatMap(\.capabilities))
        return ModelProfile(
            id: "consent-preview",
            name: first.provider.capitalized,
            provider: first.provider,
            modelID: first.id,
            baseURL: first.baseURL,
            capabilities: Array(capabilities)
        )
    }

    private func requestAdd(_ models: [ModelProbeService.DiscoveredModel]) {
        guard let first = models.first else { return }
        let preview = ModelProfile(
            id: "consent-preview",
            name: first.provider.capitalized,
            provider: first.provider,
            modelID: first.id,
            baseURL: first.baseURL,
            capabilities: Array(Set(models.flatMap(\.capabilities)))
        )
        if RemoteAIConsentStore.isAuthorized(for: preview) {
            onAddModels(models, probeKey)
            dismiss()
        } else {
            pendingConsentModels = models
        }
    }

    private func toggleModel(_ id: String) {
        if selectedModels.contains(id) {
            selectedModels.remove(id)
        } else {
            selectedModels.insert(id)
        }
    }

    private func runProbe() {
        probing = true
        probeError = nil
        probeResult = nil
        selectedModels = []

        Task {
            do {
                let result = try await ModelProbeService.probe(
                    baseURL: probeURL,
                    apiKey: probeKey.isEmpty ? nil : probeKey,
                    provider: probeProvider
                )
                await MainActor.run {
                    probeResult = result
                    selectedModels = Set(result.models.map(\.id))
                    probing = false
                }
            } catch {
                await MainActor.run {
                    probeError = error.localizedDescription
                    probing = false
                }
            }
        }
    }
}
