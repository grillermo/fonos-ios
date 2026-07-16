import SwiftUI
import UniformTypeIdentifiers

private struct ModelProviderOption {
    let id: String
    let label: String
    let icon: String
}

/// Sheet for adding or editing a model profile.
struct ModelProfileForm: View {
    var initialProfile: ModelProfile?
    var existingProfileIDs: Set<String> = []
    let onSave: (ModelProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    // Provider selection
    @State private var selectedProvider: String = "openai"

    // Form fields
    @State private var name: String = ""
    @State private var modelID: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var apiKeyWasEdited = false
    @State private var hasStt: Bool = false
    @State private var hasLlm: Bool = true
    @State private var sttAPI: String = "whisper"
    @State private var pendingConsentProfile: ModelProfile?
    @State private var credentialError: String?
    @State private var credentialReadFailed = false

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
                commitSave(profile, grantConsent: true)
            }
        } message: { profile in
            Text(RemoteAIConsentStore.disclosure(for: profile))
        }
        .alert("Credential unavailable", isPresented: Binding(
            get: { credentialError != nil },
            set: { if !$0 { credentialError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(credentialError ?? "")
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

            SecureField(
                "API Key (stored in Keychain)",
                text: Binding(
                    get: { apiKey },
                    set: {
                        apiKey = $0
                        apiKeyWasEdited = true
                    }
                )
            )
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
        ) && !credentialReadFailed
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
        do {
            apiKey = try keychainModels.get(profile.id) ?? ""
            apiKeyWasEdited = false
            credentialReadFailed = false
        } catch {
            credentialReadFailed = true
            credentialError = "The stored API key could not be read. This model was not changed. \(error.localizedDescription)"
        }
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
            var reservedIDs = existingProfileIDs
            profileID = ModelProfileIdentifier.make(
                provider: selectedProvider,
                reservedIDs: &reservedIDs
            )
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

    private func commitSave(_ profile: ModelProfile, grantConsent: Bool = false) {
        // The credential remains in Keychain and is never placed in AppConfig
        // or the remote-AI consent record.
        let update = Self.credentialUpdates(
            profile: profile,
            apiKey: apiKey,
            initialProfile: initialProfile,
            apiKeyWasEdited: apiKeyWasEdited
        )
        do {
            try ModelCredentialTransaction.apply(update)
        } catch {
            credentialError = error.localizedDescription
            return
        }
        if grantConsent { RemoteAIConsentStore.grant(for: profile) }
        onSave(profile)
        dismiss()
    }

    /// Pure save decision kept testable: clearing an existing model's field is
    /// an explicit Keychain deletion. An existing key is never carried to a
    /// different provider/service base unless the user explicitly edits the
    /// credential field, while a brand-new keyless local model performs no
    /// unnecessary Keychain operation.
    nonisolated static func credentialUpdates(
        profile: ModelProfile,
        apiKey: String,
        initialProfile: ModelProfile?,
        apiKeyWasEdited: Bool
    ) -> [ModelCredentialUpdate] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let initialProfile,
           !ScenarioImporter.hasSameCredentialScope(initialProfile, profile),
           !apiKeyWasEdited {
            return [ModelCredentialUpdate(profileID: profile.id, value: nil)]
        }
        if !key.isEmpty {
            return [ModelCredentialUpdate(profileID: profile.id, value: key)]
        }
        return initialProfile == nil
            ? []
            : [ModelCredentialUpdate(profileID: profile.id, value: nil)]
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
