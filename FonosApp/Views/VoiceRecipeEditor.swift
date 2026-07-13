import SwiftUI

/// The complete, persistence-ready value produced by `VoiceRecipeEditor`.
/// Callers upsert `definition` into `AppConfig.workflows`, then upsert every
/// `widgetOverlay` into `AppConfig.widgets` by id.
struct VoiceRecipeEditorResult: Equatable, Sendable {
    let definition: WorkflowDefinition
    let widgetOverlays: [WorkflowWidget]
}

/// A guided mobile editor for the iOS-supported voice-recipe subset:
/// microphone → STT → zero or more LLM processors → one or more outputs.
///
/// The editor never mutates `catalog`. Built-in or multiply-referenced widgets
/// are cloned only when their editable fields actually change; untouched
/// widgets keep their original ids. This lets a recipe be edited without
/// silently changing every other recipe that shares one of its components.
struct VoiceRecipeEditor: View {
    @Environment(\.dismiss) private var dismiss

    private let catalog: WorkflowCatalog
    private let operationalConfig: AppConfig?
    private let modelProfiles: [ModelProfile]
    private let vocabBooks: [VocabBook]
    private let onSave: (VoiceRecipeEditorResult) -> Void
    private let onCancel: (() -> Void)?

    @State private var draft: VoiceRecipeDraft
    @State private var expandedLLMID: UUID?

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let background = Color(hex: "#1a1917")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textSecondary = Color(hex: "#fafaf9").opacity(0.56)
    private let rowBackground = Color.white.opacity(0.045)

    init(
        definition: WorkflowDefinition? = nil,
        catalog: WorkflowCatalog,
        operationalConfig: AppConfig? = nil,
        modelProfiles: [ModelProfile],
        vocabBooks: [VocabBook] = [],
        onSave: @escaping (VoiceRecipeEditorResult) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.catalog = catalog
        self.operationalConfig = operationalConfig
        self.modelProfiles = modelProfiles
        self.vocabBooks = vocabBooks
        self.onSave = onSave
        self.onCancel = onCancel

        let initialDraft = VoiceRecipeDraft.make(
            definition: definition,
            catalog: catalog
        )
        _draft = State(initialValue: initialDraft)
        _expandedLLMID = State(initialValue: initialDraft.llms.first?.id)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                background.ignoresSafeArea()

                Form {
                    previewSection
                    identitySection
                    sourceSection
                    transcriptionSection
                    llmSection
                    outputSection

                    if !editorWarnings.isEmpty {
                        warningSection
                    }

                    if !validationIssues.isEmpty {
                        validationSection
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(
                draft.originalDefinition == nil
                    ? String(localized: "New recipe")
                    : String(localized: "Edit recipe")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                    .foregroundColor(amber)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft.materializedResult())
                        dismiss()
                    }
                    .foregroundColor(amber)
                    .disabled(!validationIssues.isEmpty)
                    .accessibilityHint(
                        validationIssues.isEmpty
                            ? String(localized: "Saves this recipe")
                            : String(localized: "Resolve the listed recipe issues before saving")
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(amber)
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            VoiceRecipePipelinePreview(draft: draft)
                .listRowBackground(rowBackground)
                .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        } header: {
            sectionHeader("Recipe")
        } footer: {
            Text("Outputs receive the same final text in listed order; they do not feed into one another.")
                .foregroundColor(textSecondary)
        }
    }

    private var identitySection: some View {
        Section {
            TextField("Recipe name", text: $draft.name)
                .foregroundColor(textPrimary)
                .textInputAutocapitalization(.sentences)
                .listRowBackground(rowBackground)

            HStack(spacing: 12) {
                Text("Icon")
                    .foregroundColor(textPrimary)
                Spacer(minLength: 16)
                TextField("Emoji or SF Symbol", text: $draft.icon)
                    .multilineTextAlignment(.trailing)
                    .foregroundColor(textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .listRowBackground(rowBackground)
        } header: {
            sectionHeader("1 · Identity")
        } footer: {
            Text("The recipe id stays stable when its name or icon changes.")
                .foregroundColor(textSecondary)
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Microphone", selection: $draft.source.capture) {
                ForEach(VoiceRecipeCapture.allCases) { capture in
                    Label(capture.label, systemImage: capture.icon)
                        .tag(capture)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(rowBackground)
        } header: {
            sectionHeader("2 · Capture")
        } footer: {
            Text("Hold and toggle are stored in the recipe source. A calling surface may disclose and apply its own capture adapter.")
                .foregroundColor(textSecondary)
        }
    }

    private var transcriptionSection: some View {
        Section {
            VoiceRecipeSTTEditor(
                draft: $draft.stt,
                profiles: modelProfiles.filter(\.hasSTT),
                vocabBooks: vocabBooks,
                tint: amber,
                textPrimary: textPrimary,
                textSecondary: textSecondary
            )
            .listRowBackground(rowBackground)
        } header: {
            sectionHeader("3 · Transcription")
        } footer: {
            Text("Recognition books bias STT and correct its transcript. Each AI processor can mount separate glossary books below.")
                .foregroundColor(textSecondary)
        }
    }

    private var llmSection: some View {
        Section {
            if draft.llms.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "text.badge.checkmark")
                        .foregroundColor(green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No AI processor")
                            .foregroundColor(textPrimary)
                            .font(.subheadline.weight(.semibold))
                        Text("The corrected transcript goes straight to the selected outputs.")
                            .foregroundColor(textSecondary)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(rowBackground)
            }

            ForEach(Array(draft.llms.enumerated()), id: \.element.id) { index, llm in
                VoiceRecipeLLMEditorCard(
                    draft: llmBinding(id: llm.id, fallback: llm),
                    index: index,
                    count: draft.llms.count,
                    isExpanded: Binding(
                        get: { expandedLLMID == llm.id },
                        set: { expandedLLMID = $0 ? llm.id : nil }
                    ),
                    profiles: modelProfiles.filter(\.hasLLM),
                    vocabBooks: vocabBooks,
                    tint: green,
                    textPrimary: textPrimary,
                    textSecondary: textSecondary,
                    onMoveUp: { moveLLM(id: llm.id, by: -1) },
                    onMoveDown: { moveLLM(id: llm.id, by: 1) },
                    onDelete: { removeLLM(id: llm.id) }
                )
                .listRowBackground(rowBackground)
            }

            Button {
                let id = draft.appendLLM()
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedLLMID = id
                }
            } label: {
                Label("Add AI processor", systemImage: "plus.circle.fill")
                    .foregroundColor(green)
            }
            .listRowBackground(rowBackground)
        } header: {
            sectionHeader("4 · AI processors")
        } footer: {
            Text("Processors run from top to bottom. Each one receives the previous processor's text.")
                .foregroundColor(textSecondary)
        }
    }

    private var outputSection: some View {
        Section {
            Toggle(isOn: $draft.insertOutput.enabled) {
                outputLabel(
                    title: String(localized: "Insert at cursor"),
                    detail: draft.insertOutput.detail,
                    icon: "keyboard"
                )
            }
            .tint(amber)
            .listRowBackground(rowBackground)

            if draft.insertOutput.enabled {
                Toggle(isOn: $draft.insertOutput.pressEnter) {
                    outputLabel(
                        title: String(localized: "Press Enter after insertion"),
                        detail: draft.insertOutput.supportsPressEnter
                            ? String(localized: "The keyboard submits the inserted text after a successful delivery.")
                            : String(localized: "This legacy return output does not support press_enter."),
                        icon: "return"
                    )
                }
                .disabled(!draft.insertOutput.supportsPressEnter)
                .opacity(draft.insertOutput.supportsPressEnter ? 1 : 0.55)
                .tint(amber)
                .listRowBackground(rowBackground)
            }

            Toggle(isOn: $draft.clipboardOutput.enabled) {
                outputLabel(
                    title: String(localized: "Copy to clipboard"),
                    detail: draft.clipboardOutput.detail,
                    icon: "doc.on.clipboard"
                )
            }
            .tint(amber)
            .listRowBackground(rowBackground)

            if !draft.insertOutput.enabled && !draft.clipboardOutput.enabled {
                Label("Choose at least one output.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.red.opacity(0.86))
                    .listRowBackground(Color.red.opacity(0.07))
            }
        } header: {
            sectionHeader("5 · Outputs")
        }
    }

    private var validationSection: some View {
        Section {
            ForEach(validationIssues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundColor(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.red.opacity(0.07))
            }
        } header: {
            sectionHeader("Needs attention")
        }
    }

    private var warningSection: some View {
        Section {
            ForEach(editorWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(amber.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(amber.opacity(0.055))
            }
        } header: {
            sectionHeader("Review")
        }
    }

    // MARK: - Editing actions

    private func llmBinding(
        id: UUID,
        fallback: VoiceRecipeLLMDraft
    ) -> Binding<VoiceRecipeLLMDraft> {
        Binding(
            get: { draft.llms.first(where: { $0.id == id }) ?? fallback },
            set: { updated in
                guard let index = draft.llms.firstIndex(where: { $0.id == id }) else { return }
                draft.llms[index] = updated
            }
        )
    }

    private func moveLLM(id: UUID, by offset: Int) {
        guard let from = draft.llms.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard draft.llms.indices.contains(to) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            draft.llms.swapAt(from, to)
        }
    }

    private func removeLLM(id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            draft.llms.removeAll { $0.id == id }
            if expandedLLMID == id {
                expandedLLMID = nil
            }
        }
    }

    // MARK: - Validation

    private var validationIssues: [String] {
        VoiceRecipeEditorValidator(
            draft: draft,
            catalog: catalog,
            operationalConfig: operationalConfig,
            modelProfiles: modelProfiles
        ).issues()
    }

    private var editorWarnings: [String] {
        draft.llms.enumerated().compactMap { index, llm in
            guard !llm.userTemplate.contains("{text}") else { return nil }
            return String(
                format: String(localized: "AI processor %lld uses a fixed user template. It will not include text from the previous step."),
                Int64(index + 1)
            )
        }
    }

    // MARK: - Small view helpers

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundColor(textSecondary)
            .textCase(.uppercase)
    }

    private func outputLabel(title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundColor(amber)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundColor(textPrimary)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .foregroundColor(textSecondary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct VoiceRecipeEditorValidator {
    let draft: VoiceRecipeDraft
    let catalog: WorkflowCatalog
    let operationalConfig: AppConfig?
    let modelProfiles: [ModelProfile]

    func issues() -> [String] {
        var issues = draft.blockingIssues
        appendIdentityAndOutputIssues(to: &issues)
        appendModelIssues(to: &issues)
        if issues.isEmpty, let operationalIssue = validateMaterializedRecipe() {
            issues.append(operationalIssue)
        }
        var seen: Set<String> = []
        return issues.filter { seen.insert($0).inserted }
    }

    private func appendIdentityAndOutputIssues(to issues: inout [String]) {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(String(localized: "Enter a recipe name."))
        }
        if !draft.insertOutput.enabled && !draft.clipboardOutput.enabled {
            issues.append(String(localized: "Choose at least one output."))
        }
    }

    private func appendModelIssues(to issues: inout [String]) {
        if !draft.stt.modelProfileID.isEmpty,
           draft.stt.modelProfileID != ModelProfileReference.appleSpeech,
           !modelProfiles.contains(where: {
               $0.id == draft.stt.modelProfileID && $0.hasSTT
           }) {
            issues.append(String(
                format: String(localized: "The transcription model '%@' is unavailable. Choose another model or Use default."),
                draft.stt.modelProfileID
            ))
        }

        for (index, llm) in draft.llms.enumerated() {
            if llm.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(String(
                    format: String(localized: "AI processor %lld needs a name."),
                    Int64(index + 1)
                ))
            }
            if !(1...128_000).contains(llm.maxTokens) {
                issues.append(String(
                    format: String(localized: "AI processor %lld max tokens must be between 1 and 128000."),
                    Int64(index + 1)
                ))
            }
            if !llm.modelProfileID.isEmpty,
               !modelProfiles.contains(where: {
                   $0.id == llm.modelProfileID && $0.hasLLM
               }) {
                issues.append(String(
                    format: String(localized: "AI processor %lld model '%@' is unavailable. Choose another model or Use default."),
                    Int64(index + 1),
                    llm.modelProfileID
                ))
            }
        }
    }

    private func validateMaterializedRecipe() -> String? {
        let result = draft.materializedResult()
        var widgets = catalog.widgets
        for overlay in result.widgetOverlays {
            if let index = widgets.firstIndex(where: { $0.id == overlay.id }) {
                widgets[index] = overlay
            } else {
                widgets.append(overlay)
            }
        }
        let validationCatalog = WorkflowCatalog(
            widgets: widgets,
            workflows: [result.definition]
        )
        do {
            if let operationalConfig {
                _ = try VoiceWorkflowOperationalValidator.validateMicrophone(
                    definition: result.definition,
                    catalog: validationCatalog,
                    config: operationalConfig
                )
            } else {
                _ = try VoiceWorkflowEngine().validate(
                    definition: result.definition,
                    catalog: validationCatalog
                )
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
