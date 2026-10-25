import SwiftUI
import UniformTypeIdentifiers

/// Collision-safe identity shared by manual and probed model creation. Profile
/// IDs also key credentials, so they must never be derived from randomized
/// `hashValue` or second-resolution timestamps.
enum ModelProfileIdentifier {
    static func make(
        provider: String,
        reservedIDs: inout Set<String>,
        uuid: UUID = UUID()
    ) -> String {
        let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.isEmpty ? "model" : trimmed.lowercased()
        let base = "\(prefix)-\(uuid.uuidString.lowercased())"
        var candidate = base
        var suffix = 2
        while reservedIDs.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        reservedIDs.insert(candidate)
        return candidate
    }
}

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
    @State private var modelCredentialError: String?
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
                onImport: { _ in
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
            ModelProfileForm(
                existingProfileIDs: Set(config.modelProfiles.map(\.id)),
                onSave: { profile in
                    guard !config.modelProfiles.contains(where: { $0.id == profile.id }) else {
                        modelCredentialError = "A model with this internal identity already exists. Please add it again."
                        return
                    }
                    config.modelProfiles.append(profile)
                }
            )
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
                    addProbedModels(models, apiKey: apiKey)
                }
            )
        }
        .sheet(item: $editingProfile) { profile in
            ModelProfileForm(
                initialProfile: profile,
                existingProfileIDs: Set(config.modelProfiles.map(\.id)),
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
        .alert("Credential update failed", isPresented: .init(
            get: { modelCredentialError != nil },
            set: { if !$0 { modelCredentialError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(modelCredentialError ?? "")
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
        do {
            try ModelCredentialTransaction.apply([
                ModelCredentialUpdate(profileID: id, value: nil)
            ])
        } catch {
            modelCredentialError = error.localizedDescription
            return
        }
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

    private func addProbedModels(
        _ models: [ModelProbeService.DiscoveredModel],
        apiKey: String
    ) -> String? {
        var reservedIDs = Set(config.modelProfiles.map(\.id))
        let profiles = models.map { model in
            let profileID = ModelProfileIdentifier.make(
                provider: model.provider,
                reservedIDs: &reservedIDs
            )
            return ModelProfile(
                id: profileID,
                name: model.name,
                provider: model.provider,
                modelID: model.id,
                baseURL: model.baseURL,
                capabilities: model.capabilities,
                sttAPI: model.capabilities.contains("stt") && model.provider == "openrouter"
                    ? "chat"
                    : nil
            )
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !key.isEmpty {
                try ModelCredentialTransaction.apply(
                    profiles.map { ModelCredentialUpdate(profileID: $0.id, value: key) }
                )
            }
        } catch {
            return error.localizedDescription
        }
        config.modelProfiles.append(contentsOf: profiles)
        return nil
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
