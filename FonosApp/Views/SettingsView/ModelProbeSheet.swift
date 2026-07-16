import SwiftUI
import UniformTypeIdentifiers

// MARK: - Probe Sheet

private struct ProbeProviderOption {
    let id: String
    let label: String
    let defaultURL: String
}

/// Sheet for probing an endpoint to discover available models.
struct ProbeSheet: View {
    @Binding var probeURL: String
    @Binding var probeKey: String
    @Binding var probeProvider: String
    @Binding var probing: Bool
    @Binding var probeError: String?
    @Binding var probeResult: ModelProbeService.ProbeResult?
    /// Returns a user-visible error when credentials could not be persisted.
    let onAddModels: (_ models: [ModelProbeService.DiscoveredModel], _ apiKey: String) -> String?

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
                let models = pendingConsentModels
                pendingConsentModels = []
                if let error = onAddModels(models, probeKey) {
                    probeError = error
                } else {
                    RemoteAIConsentStore.grant(for: profile)
                    dismiss()
                }
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
            if let error = onAddModels(models, probeKey) {
                probeError = error
            } else {
                dismiss()
            }
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
