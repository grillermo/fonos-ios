import SwiftUI

// MARK: - Modes Tab

/// Settings tab for managing processing mode configurations.
/// Shows built-in and custom modes with pipeline details, and allows add/edit/delete.
struct ModesTab: View {
    @Binding var config: AppConfig

    @State private var showAddMode = false
    @State private var editingModeConfig: ModeConfig?
    @State private var expandedID: String?

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let cardBg = Color.white.opacity(0.02)
    private let cardBorder = Color.white.opacity(0.04)
    private let separator = Color.white.opacity(0.04)

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundColor(amber)

                        Text("Voice flow")
                            .font(.headline)
                            .foregroundColor(textPrimary)
                    }

                    Text("Main-app dictation follows a clear path. Speech is transcribed first, your vocabulary is applied deterministically, then AI processing runs only when the selected mode requests it.")
                        .font(.subheadline)
                        .foregroundColor(textDim)
                        .fixedSize(horizontal: false, vertical: true)

                    ModeFlowStrip(
                        requiresLLM: config.activeModeConfig?.mode.requiresLLM ?? false,
                        hasLLM: config.activeModeConfig.map { llmModel(for: $0) != nil } ?? false,
                        amber: amber,
                        green: green,
                        textDim: textDim
                    )
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("modes.voiceFlowOverview")
                .listRowBackground(cardBg)
                .listRowSeparatorTint(separator)
            }

            Section {
                ForEach(config.modeConfigs, id: \.id) { modeConfig in
                    ModeConfigRow(
                        modeConfig: modeConfig,
                        isExpanded: expandedID == modeConfig.id,
                        isActive: config.activeModeID == modeConfig.id,
                        sttModel: sttModel(for: modeConfig),
                        llmModel: llmModel(for: modeConfig),
                        amber: amber,
                        green: green,
                        textPrimary: textPrimary,
                        textDim: textDim,
                        cardBg: cardBg,
                        separator: separator,
                        onTap: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                expandedID = expandedID == modeConfig.id ? nil : modeConfig.id
                            }
                        },
                        onEdit: {
                            editingModeConfig = modeConfig
                        },
                        onActivate: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                config.activeModeID = modeConfig.id
                            }
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !modeConfig.isBuiltIn {
                            Button(role: .destructive) {
                                config.modeConfigs.removeAll { $0.id == modeConfig.id }
                                if config.activeModeID == modeConfig.id {
                                    config.activeModeID = "raw"
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                // Add Mode button
                Button {
                    showAddMode = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(amber)
                        Text("Add Mode")
                            .foregroundColor(amber)
                    }
                }
                .listRowBackground(cardBg)
                .listRowSeparatorTint(separator)
            } header: {
                sectionHeader("Processing Modes")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showAddMode) {
            ModeConfigForm(
                availableSTTModels: sttModels,
                availableLLMModels: llmModels,
                onSave: { newConfig in
                    config.modeConfigs.append(newConfig)
                }
            )
        }
        .sheet(item: $editingModeConfig) { modeConfig in
            ModeConfigForm(
                initialConfig: modeConfig,
                availableSTTModels: sttModels,
                availableLLMModels: llmModels,
                onSave: { updated in
                    if let idx = config.modeConfigs.firstIndex(where: { $0.id == modeConfig.id }) {
                        config.modeConfigs[idx] = updated
                    }
                }
            )
        }
    }

    // MARK: - Helpers

    private var sttModels: [ModelProfile] {
        config.modelProfiles.filter(\.hasSTT)
    }

    private var llmModels: [ModelProfile] {
        config.modelProfiles.filter(\.hasLLM)
    }

    private func sttModel(for modeConfig: ModeConfig) -> ModelProfile? {
        let id = config.effectiveSTTProfileID(forModeID: modeConfig.id)
        if id.isEmpty {
            return ModelProfile(
                id: "apple-speech",
                name: "Apple Speech",
                provider: "apple",
                modelID: "system",
                capabilities: ["stt"]
            )
        }
        return config.modelProfiles.first(where: { $0.id == id && $0.hasSTT })
    }

    private func llmModel(for modeConfig: ModeConfig) -> ModelProfile? {
        let id = config.effectiveLLMProfileID(forModeID: modeConfig.id)
        return config.modelProfiles.first(where: { $0.id == id && $0.hasLLM })
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(textDim)
            .textCase(.uppercase)
    }
}

// MARK: - Mode Config Row

private struct ModeConfigRow: View {
    let modeConfig: ModeConfig
    let isExpanded: Bool
    let isActive: Bool
    let sttModel: ModelProfile?
    let llmModel: ModelProfile?
    let amber: Color
    let green: Color
    let textPrimary: Color
    let textDim: Color
    let cardBg: Color
    let separator: Color
    let onTap: () -> Void
    let onEdit: () -> Void
    let onActivate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: modeConfig.icon)
                        .foregroundColor(amber)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(modeDisplayName)
                                .foregroundColor(textPrimary)
                                .font(.body)

                            if isActive {
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(Color.black.opacity(0.75))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule()
                                            .fill(green)
                                    )
                            }

                            if modeConfig.isBuiltIn {
                                Text("Built-in")
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(textDim)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.white.opacity(0.06))
                                    )
                            }
                        }

                        ModeFlowStrip(
                            requiresLLM: modeConfig.mode.requiresLLM,
                            hasLLM: llmModel != nil,
                            amber: amber,
                            green: green,
                            textDim: textDim
                        )
                        .padding(.top, 5)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(textDim)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(PlainButtonStyle())
            .accessibilityLabel(modeDisplayName)
            .accessibilityValue(modeAccessibilityValue)
            .accessibilityHint(
                isExpanded
                    ? String(localized: "Collapses flow details")
                    : String(localized: "Expands flow details")
            )
            .accessibilityIdentifier("modes.mode.\(modeConfig.id)")

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.top, 4)

                    // Description
                    if !modeConfig.description.isEmpty {
                        Text(modeConfig.description)
                            .font(.system(size: 13))
                            .foregroundColor(textDim)
                    }

                    // Resolved flow steps
                    VStack(alignment: .leading, spacing: 10) {
                        pipelineStep(
                            icon: "waveform",
                            label: "Speech-to-Text",
                            value: sttModel?.name ?? String(localized: "Unavailable — Apple Speech fallback"),
                            color: sttModel == nil ? Color.orange : amber,
                            statusIcon: sttModel == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )

                        pipelineStep(
                            icon: "text.badge.checkmark",
                            label: "Vocabulary",
                            value: String(localized: "Deterministic corrections"),
                            color: green,
                            statusIcon: "checkmark.circle.fill"
                        )

                        llmPipelineStep
                    }

                    HStack(spacing: 10) {
                        if !isActive {
                            Button(action: onActivate) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle")
                                    Text("Use this mode")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .foregroundColor(Color.black.opacity(0.75))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(green)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityIdentifier("modes.use.\(modeConfig.id)")
                        }

                        Spacer()

                        if !modeConfig.isBuiltIn {
                            Button(action: onEdit) {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil")
                                    Text("Edit")
                                        .font(.subheadline.weight(.medium))
                                }
                                .foregroundColor(amber)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(amber.opacity(0.1))
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .accessibilityIdentifier("modes.edit.\(modeConfig.id)")
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .listRowBackground(cardBg)
        .listRowSeparatorTint(separator)
    }

    @ViewBuilder
    private var llmPipelineStep: some View {
        if !modeConfig.mode.requiresLLM {
            pipelineStep(
                icon: "sparkles",
                label: "AI Processing",
                value: String(localized: "Skipped — raw transcript"),
                color: textDim,
                statusIcon: "minus.circle.fill"
            )
        } else if let llmModel {
            pipelineStep(
                icon: "sparkles",
                label: "AI Processing",
                value: llmModel.name,
                color: green,
                statusIcon: "checkmark.circle.fill"
            )
        } else {
            pipelineStep(
                icon: "sparkles",
                label: "AI Processing",
                value: String(localized: "Not configured — transcript fallback"),
                color: Color.orange,
                statusIcon: "exclamationmark.triangle.fill"
            )
        }
    }

    private func pipelineStep(
        icon: String,
        label: LocalizedStringKey,
        value: String,
        color: Color,
        statusIcon: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(color)

                Text(value)
                    .font(.subheadline)
                    .foregroundColor(textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundColor(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value)
    }

    private var modeDisplayName: String {
        guard modeConfig.isBuiltIn else { return modeConfig.name }
        switch modeConfig.id {
        case "raw": return String(localized: "Raw")
        case "polish": return String(localized: "Polish")
        case "formal": return String(localized: "Formal")
        case "translate": return String(localized: "Translate")
        default: return modeConfig.name
        }
    }

    private var modeAccessibilityValue: String {
        let activity = isActive
            ? String(localized: "Active mode")
            : String(localized: "Inactive mode")
        let flow: String
        if !modeConfig.mode.requiresLLM {
            flow = String(localized: "AI processing is skipped for a raw transcript")
        } else if llmModel == nil {
            flow = String(localized: "AI processing is not configured; transcript fallback will be used")
        } else {
            flow = String(localized: "All three steps are configured")
        }
        return "\(activity). \(flow)"
    }
}

// MARK: - Flow Strip

private struct ModeFlowStrip: View {
    let requiresLLM: Bool
    let hasLLM: Bool
    let amber: Color
    let green: Color
    let textDim: Color

    private var aiColor: Color {
        if !requiresLLM { return textDim }
        return hasLLM ? green : Color.orange
    }

    private var aiIcon: String {
        if !requiresLLM { return "minus.circle" }
        return hasLLM ? "sparkles" : "exclamationmark.triangle.fill"
    }

    private var accessibilityValue: String {
        if !requiresLLM {
            return String(localized: "AI processing is skipped for a raw transcript")
        }
        if !hasLLM {
            return String(localized: "AI processing is not configured; transcript fallback will be used")
        }
        return String(localized: "All three steps are configured")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                step(icon: "waveform", title: "Speech", color: amber)
                connector(systemName: "chevron.right")
                step(icon: "text.badge.checkmark", title: "Vocabulary", color: green)
                connector(systemName: "chevron.right")
                step(icon: aiIcon, title: "AI", color: aiColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                step(icon: "waveform", title: "Speech", color: amber)
                connector(systemName: "chevron.down")
                    .padding(.leading, 14)
                step(icon: "text.badge.checkmark", title: "Vocabulary", color: green)
                connector(systemName: "chevron.down")
                    .padding(.leading, 14)
                step(icon: aiIcon, title: "AI", color: aiColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Speech, then Vocabulary, then AI"))
        .accessibilityValue(accessibilityValue)
    }

    private func step(icon: String, title: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.1))
        )
    }

    private func connector(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.bold))
            .foregroundColor(textDim.opacity(0.7))
    }
}

// MARK: - Mode Config Form

/// Sheet for creating or editing a ModeConfig.
struct ModeConfigForm: View {
    var initialConfig: ModeConfig?
    let availableSTTModels: [ModelProfile]
    let availableLLMModels: [ModelProfile]
    let onSave: (ModeConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    // Identity
    @State private var icon: String = "slider.horizontal.3"
    @State private var name: String = ""
    @State private var description: String = ""

    // STT
    @State private var sttModelID: String = ""  // "" = use default
    @State private var sttPrompt: String = ""
    @State private var sttTemperature: Double = 0.0
    @State private var showSTTAdvanced: Bool = false

    // LLM
    @State private var llmEnabled: Bool = true
    @State private var llmModelID: String = ""  // "" = use default
    @State private var systemPrompt: String = ""
    @State private var userTemplate: String = "{text}"
    @State private var llmTemperature: Double = 0.7
    @State private var maxTokens: Int = 1024
    @State private var showLLMAdvanced: Bool = false

    // Output
    @State private var outputLanguage: String = "auto"
    @State private var autoPaste: Bool = false

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let bg = Color(hex: "#1a1917")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let cardBg = Color.white.opacity(0.06)

    var body: some View {
        NavigationStack {
            ZStack {
                bg.ignoresSafeArea()

                Form {
                    identitySection
                    sttSection
                    vocabularySection
                    llmSection
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(initialConfig == nil ? "New Mode" : "Edit Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(amber)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .foregroundColor(amber)
                    .disabled(!canSave)
                }
            }
        }
        .onAppear(perform: populateFromInitial)
    }

    // MARK: - Identity Section

    private var identitySection: some View {
        Section {
            HStack(spacing: 12) {
                Text("Icon")
                    .foregroundColor(textPrimary)
                    .frame(width: 50, alignment: .leading)
                TextField("SF Symbol or emoji", text: $icon)
                    .foregroundColor(textPrimary)
                    .tint(amber)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
            .listRowBackground(cardBg)

            TextField("Name", text: $name)
                .foregroundColor(textPrimary)
                .tint(amber)
                .listRowBackground(cardBg)

            TextField("Description (optional)", text: $description)
                .foregroundColor(textPrimary)
                .tint(amber)
                .listRowBackground(cardBg)
        } header: {
            formHeader("Identity")
        }
    }

    // MARK: - STT Section

    private var sttSection: some View {
        Section {
            // Model picker
            Picker(selection: $sttModelID) {
                Text("Default").tag("")
                ForEach(availableSTTModels) { model in
                    Text(model.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .tag(model.id)
                }
            } label: {
                Text("Model")
                    .foregroundColor(textPrimary)
            }
            .foregroundColor(textPrimary)
            .listRowBackground(cardBg)

            // Advanced disclosure
            DisclosureGroup("Advanced", isExpanded: $showSTTAdvanced) {
                TextField("Whisper Prompt Hint", text: $sttPrompt)
                    .foregroundColor(textPrimary)
                    .tint(amber)
                    .listRowBackground(cardBg)
                    .font(.system(size: 14))
            }
            .foregroundColor(textDim)
            .listRowBackground(cardBg)
        } header: {
            formHeader("Step 1: Speech-to-Text")
        }
    }

    // MARK: - Vocabulary Section

    private var vocabularySection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.badge.checkmark")
                    .foregroundColor(green)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Deterministic corrections")
                        .font(.body.weight(.medium))
                        .foregroundColor(textPrimary)

                    Text("Vocabulary entries for this mode are applied after transcription and before AI processing.")
                        .font(.subheadline)
                        .foregroundColor(textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundColor(textDim)
                    .accessibilityLabel("Read only")
            }
            .padding(.vertical, 4)
            .listRowBackground(cardBg)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("modeForm.vocabularyStep")
        } header: {
            formHeader("Step 2: Vocabulary")
        }
    }

    // MARK: - LLM Section

    private var llmSection: some View {
        Section {
            Toggle("Enable LLM Processing", isOn: $llmEnabled)
                .tint(amber)
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)

            if llmEnabled {
                Picker(selection: $llmModelID) {
                    Text("Default").tag("")
                    ForEach(availableLLMModels) { model in
                        Text(model.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .tag(model.id)
                    }
                } label: {
                    Text("Model")
                        .foregroundColor(textPrimary)
                }
                .foregroundColor(textPrimary)
                .listRowBackground(cardBg)

                // System prompt
                VStack(alignment: .leading, spacing: 6) {
                    Text("System Prompt")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textDim)
                    TextEditor(text: $systemPrompt)
                        .foregroundColor(textPrimary)
                        .tint(amber)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                }
                .listRowBackground(cardBg)

                // User template
                TextField("User Template ({text})", text: $userTemplate)
                    .foregroundColor(textPrimary)
                    .tint(amber)
                    .font(.system(size: 14, design: .monospaced))
                    .listRowBackground(cardBg)

                // Advanced disclosure
                DisclosureGroup("Advanced", isExpanded: $showLLMAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Temperature")
                                .foregroundColor(textPrimary)
                            Spacer()
                            Text(String(format: "%.2f", llmTemperature))
                                .foregroundColor(textDim)
                                .monospacedDigit()
                        }
                        Slider(value: $llmTemperature, in: 0.0...2.0, step: 0.05)
                            .tint(amber)
                    }
                    .listRowBackground(cardBg)

                    Picker("Max Tokens", selection: $maxTokens) {
                        Text("256").tag(256)
                        Text("512").tag(512)
                        Text("1024").tag(1024)
                        Text("2048").tag(2048)
                        Text("4096").tag(4096)
                    }
                    .foregroundColor(textPrimary)
                    .listRowBackground(cardBg)

                }
                .foregroundColor(textDim)
                .listRowBackground(cardBg)
            }
        } header: {
            formHeader("Step 3: AI Processing")
        }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !icon.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func formHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(textDim)
            .textCase(.uppercase)
    }

    private func populateFromInitial() {
        guard let cfg = initialConfig else { return }
        icon = cfg.icon
        name = cfg.name
        description = cfg.description
        sttModelID = cfg.sttModelID ?? ""
        llmModelID = cfg.llmModelID ?? ""
        sttPrompt = cfg.sttPrompt
        sttTemperature = cfg.sttTemperature
        autoPaste = cfg.autoPaste
        outputLanguage = cfg.outputLanguage

        // Extract LLM settings from the mode
        if case .custom(let sp, let ut, let temp, let tokens) = cfg.mode {
            llmEnabled = true
            systemPrompt = sp
            userTemplate = ut
            llmTemperature = temp
            maxTokens = tokens
        } else {
            llmEnabled = cfg.mode.requiresLLM
            systemPrompt = cfg.mode.systemPrompt
            userTemplate = cfg.mode.userTemplate
        }
    }

    private func save() {
        let configID: String
        if let existing = initialConfig {
            configID = existing.id
        } else {
            configID = UUID().uuidString
        }

        // Build the Mode
        let mode: Mode
        if llmEnabled && !systemPrompt.isEmpty {
            mode = .custom(
                systemPrompt: systemPrompt,
                userTemplate: userTemplate.isEmpty ? "{text}" : userTemplate,
                temperature: llmTemperature,
                maxTokens: maxTokens
            )
        } else {
            mode = .raw
        }

        let newConfig = ModeConfig(
            id: configID,
            mode: mode,
            name: name.trimmingCharacters(in: .whitespaces),
            icon: icon.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            sttModelID: sttModelID.isEmpty ? nil : sttModelID,
            llmModelID: llmModelID.isEmpty ? nil : llmModelID,
            sttPrompt: sttPrompt,
            sttTemperature: sttTemperature,
            outputLanguage: outputLanguage,
            autoPaste: autoPaste,
            isBuiltIn: initialConfig?.isBuiltIn ?? false
        )
        onSave(newConfig)
    }
}
