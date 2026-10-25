import SwiftUI

// MARK: - Modes Tab

/// Settings tab for managing executable voice recipes.
/// This screen edits the workflow/widget graph that every recording surface
/// executes.
struct ModesTab: View {
    @Binding var config: AppConfig

    @State private var showAddRecipe = false
    @State private var editingRecipe: WorkflowDefinition?
    @State private var expandedID: String?
    @State private var vocabBooks: [VocabBook] = []
    @State private var recipeSaveError: String?

    private let vocabStore = VocabStore()

    private let amber = Color(hex: "#fbbf24")
    private let green = Color(hex: "#86efac")
    private let textPrimary = Color(hex: "#fafaf9")
    private let textDim = Color(hex: "#fafaf9").opacity(0.5)
    private let cardBg = Color.white.opacity(0.02)
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

                    Text(
                        """
                        The selected recipe runs its real source, ordered processors, and outputs in listed delivery order. \
                        Vocabulary is mounted where it is used: recognition and correction at STT, glossary context at each AI step.
                        """
                    )
                        .font(.subheadline)
                        .foregroundColor(textDim)
                        .fixedSize(horizontal: false, vertical: true)

                    if let activeWorkflow {
                        WorkflowRecipeStrip(
                            definition: activeWorkflow,
                            catalog: catalog,
                            amber: amber,
                            green: green,
                            textDim: textDim
                        )
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("modes.voiceFlowOverview")
                .listRowBackground(cardBg)
                .listRowSeparatorTint(separator)
            }

            Section {
                ForEach(voiceWorkflows, id: \.id) { workflow in
                    WorkflowDefinitionRow(
                        definition: workflow,
                        catalog: catalog,
                        isAvailable: isWorkflowRunnable(workflow),
                        isExpanded: expandedID == workflow.id,
                        isActive: config.activeVoiceWorkflowID == workflow.id,
                        isEnabled: config.isVoiceWorkflowEnabled(workflow.id),
                        amber: amber,
                        green: green,
                        textPrimary: textPrimary,
                        textDim: textDim,
                        cardBg: cardBg,
                        separator: separator,
                        onTap: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                expandedID = expandedID == workflow.id ? nil : workflow.id
                            }
                        },
                        onActivate: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                activateRecipe(workflow.id)
                            }
                        },
                        onEdit: {
                            openEditor(for: workflow)
                        },
                        // Builtins cannot be deleted, so they can be switched off instead.
                        onSetEnabled: workflow.builtin ? { enabled in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                setRecipe(workflow.id, enabled: enabled)
                            }
                        } : nil,
                        canDisable: config.enabledVoiceWorkflows.count > 1
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !workflow.builtin {
                            Button(role: .destructive) {
                                deleteRecipe(workflow)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }

                Button {
                    reloadVocabularyBooks()
                    showAddRecipe = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(amber)
                        Text("New voice recipe")
                            .foregroundColor(amber)
                    }
                }
                .accessibilityIdentifier("modes.addRecipe")
                .listRowBackground(cardBg)
                .listRowSeparatorTint(separator)
            } header: {
                sectionHeader("Voice Recipes")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showAddRecipe) {
            VoiceRecipeEditor(
                catalog: catalog,
                operationalConfig: config,
                modelProfiles: config.modelProfiles,
                vocabBooks: vocabBooks,
                onSave: { result in
                    saveRecipe(result, activate: true)
                }
            )
        }
        .sheet(item: $editingRecipe) { workflow in
            VoiceRecipeEditor(
                definition: workflow,
                catalog: catalog,
                operationalConfig: config,
                modelProfiles: config.modelProfiles,
                vocabBooks: vocabBooks,
                onSave: { result in
                    saveRecipe(result, activate: false)
                }
            )
        }
        .onAppear(perform: reloadVocabularyBooks)
        .alert("Recipe could not be saved", isPresented: Binding(
            get: { recipeSaveError != nil },
            set: { if !$0 { recipeSaveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recipeSaveError ?? "")
        }
    }

    // MARK: - Helpers

    private var catalog: WorkflowCatalog { config.workflowCatalog }

    private var voiceWorkflows: [WorkflowDefinition] {
        config.voiceWorkflows
    }

    private var activeWorkflow: WorkflowDefinition? {
        catalog.workflow(id: config.activeVoiceWorkflowID)
    }

    private func isWorkflowRunnable(_ workflow: WorkflowDefinition) -> Bool {
        (try? VoiceWorkflowOperationalValidator.validateMainAppMicrophone(
            definition: workflow,
            catalog: catalog,
            config: config
        )) != nil
    }

    private func openEditor(for workflow: WorkflowDefinition) {
        reloadVocabularyBooks()
        editingRecipe = workflow
    }

    private func reloadVocabularyBooks() {
        vocabBooks = vocabStore.books
    }

    private func saveRecipe(
        _ result: VoiceRecipeEditorResult,
        activate: Bool
    ) {
        let candidateCatalog = catalog(applying: result)
        do {
            _ = try VoiceWorkflowOperationalValidator.validateMainAppMicrophone(
                definition: result.definition,
                catalog: candidateCatalog,
                config: config
            )
        } catch {
            recipeSaveError = error.localizedDescription
            return
        }

        let previousReferences = catalog.workflow(id: result.definition.id)
            .map(referencedWidgetIDs(in:)) ?? []

        if let index = config.workflows.firstIndex(where: {
            $0.id == result.definition.id
        }) {
            config.workflows[index] = result.definition
        } else {
            config.workflows.append(result.definition)
        }

        for widget in result.widgetOverlays {
            if let index = config.widgets.firstIndex(where: { $0.id == widget.id }) {
                config.widgets[index] = widget
            } else {
                config.widgets.append(widget)
            }
        }

        let retainedReferences = referencedWidgetIDs(in: result.definition)
        removeOrphanedWidgets(previousReferences.subtracting(retainedReferences))
        expandedID = result.definition.id

        if activate {
            activateRecipe(result.definition.id)
        }
    }

    private func catalog(
        applying result: VoiceRecipeEditorResult
    ) -> WorkflowCatalog {
        var widgets = catalog.widgets
        for overlay in result.widgetOverlays {
            if let index = widgets.firstIndex(where: { $0.id == overlay.id }) {
                widgets[index] = overlay
            } else {
                widgets.append(overlay)
            }
        }

        var workflows = catalog.workflows
        if let index = workflows.firstIndex(where: {
            $0.id == result.definition.id
        }) {
            workflows[index] = result.definition
        } else {
            workflows.append(result.definition)
        }
        return WorkflowCatalog(widgets: widgets, workflows: workflows)
    }

    private func deleteRecipe(_ workflow: WorkflowDefinition) {
        let removedReferences = referencedWidgetIDs(in: workflow)
        config.workflows.removeAll { $0.id == workflow.id }

        removeOrphanedWidgets(removedReferences)
        if config.activeVoiceWorkflowID == workflow.id {
            activateFallbackRecipe()
        }
    }

    private func activateRecipe(_ workflowID: String) {
        config.disabledVoiceWorkflowIDs.removeAll { $0 == workflowID }
        config.activeVoiceWorkflowID = workflowID
    }

    /// Disabling hides a recipe from every mode picker. The last enabled
    /// recipe cannot be disabled, and disabling the active one moves the
    /// selection to another enabled recipe.
    private func setRecipe(_ workflowID: String, enabled: Bool) {
        if enabled {
            config.disabledVoiceWorkflowIDs.removeAll { $0 == workflowID }
            return
        }
        guard config.isVoiceWorkflowEnabled(workflowID),
              config.enabledVoiceWorkflows.count > 1 else { return }
        config.disabledVoiceWorkflowIDs.append(workflowID)
        if config.activeVoiceWorkflowID == workflowID {
            activateFallbackRecipe()
        }
    }

    private func activateFallbackRecipe() {
        let candidates = config.enabledVoiceWorkflows
        let fallback = candidates.first(where: {
            $0.id == "wf.dictation" && isWorkflowRunnable($0)
        }) ?? candidates.first(where: isWorkflowRunnable)
        guard let fallback else {
            config.activeVoiceWorkflowID = ""
            return
        }
        activateRecipe(fallback.id)
    }

    private func referencedWidgetIDs(
        in workflow: WorkflowDefinition
    ) -> Set<String> {
        Set([workflow.source] + workflow.processors + workflow.outputs)
    }

    private func removeOrphanedWidgets(_ candidates: Set<String>) {
        guard !candidates.isEmpty else { return }
        let referenced = Set(config.workflowCatalog.workflows.flatMap {
            [ $0.source ] + $0.processors + $0.outputs
        })
        config.widgets.removeAll { widget in
            candidates.contains(widget.id)
                && !referenced.contains(widget.id)
                && WorkflowCatalog.builtIn.widget(id: widget.id) == nil
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(textDim)
            .textCase(.uppercase)
    }
}

// MARK: - Workflow definition row

private struct WorkflowDefinitionRow: View {
    let definition: WorkflowDefinition
    let catalog: WorkflowCatalog
    let isAvailable: Bool
    let isExpanded: Bool
    let isActive: Bool
    let isEnabled: Bool
    let amber: Color
    let green: Color
    let textPrimary: Color
    let textDim: Color
    let cardBg: Color
    let separator: Color
    let onTap: () -> Void
    let onActivate: () -> Void
    let onEdit: (() -> Void)?
    let onSetEnabled: ((Bool) -> Void)?
    let canDisable: Bool

    private var nodes: [WorkflowWidget] {
        ([definition.source] + definition.processors + definition.outputs).map { id in
            catalog.widget(id: id) ?? WorkflowWidget(
                id: id,
                role: .unknown("missing"),
                typeTag: "unknown",
                name: id
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    workflowIcon
                        .foregroundColor(amber)
                        .frame(width: 22, height: 24)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text(workflowName)
                                .foregroundColor(textPrimary)
                                .font(.body)

                            if isActive {
                                Text("Active")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(Color.black.opacity(0.75))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(green))
                            }

                            if definition.builtin {
                                Text("Built-in")
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(textDim)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
                            }

                            if !isEnabled {
                                Text("Disabled")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(textDim)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                            }

                            if !isAvailable {
                                Text("Unavailable")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundColor(Color.red.opacity(0.82))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(Color.red.opacity(0.1))
                                    )
                            }
                        }

                        WorkflowRecipeStrip(
                            definition: definition,
                            catalog: catalog,
                            amber: amber,
                            green: green,
                            textDim: textDim
                        )
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(textDim)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "modes.mode.\(WorkflowMigration.legacyModeID(forWorkflowID: definition.id) ?? definition.id)"
            )

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.top, 4)

                    ForEach(Array(nodes.enumerated()), id: \.offset) { index, widget in
                        componentDetail(index: index, widget: widget)
                    }

                    Label(
                        "Vocabulary resolves per processor: STT bias and correction, then optional AI glossary context.",
                        systemImage: "text.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundColor(green.opacity(0.72))

                    if let onSetEnabled {
                        Toggle(isOn: Binding(get: { isEnabled }, set: onSetEnabled)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enabled")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(textPrimary)
                                Text(isEnabled && !canDisable
                                     ? "The only enabled recipe cannot be disabled."
                                     : "Disabled recipes are hidden from the mode bar and keyboard.")
                                    .font(.caption)
                                    .foregroundColor(textDim)
                            }
                        }
                        .tint(green)
                        .disabled(isEnabled && !canDisable)
                        .accessibilityIdentifier("modes.enabled.\(definition.id)")
                    }

                    HStack(spacing: 10) {
                        if !isActive && isAvailable && isEnabled {
                            Button(action: onActivate) {
                                Label("Use this recipe", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Color.black.opacity(0.75))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(green))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("modes.use.\(definition.id)")
                        }

                        Spacer()

                        if let onEdit {
                            Button(action: onEdit) {
                                Label("Edit", systemImage: "pencil")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(amber)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(amber.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("modes.edit.\(definition.id)")
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .listRowBackground(cardBg)
        .listRowSeparatorTint(separator)
    }

    private func componentDetail(index: Int, widget: WorkflowWidget) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: componentIcon(widget))
                .font(.caption.weight(.semibold))
                .foregroundColor(roleColor(widget.role))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(roleLabel(widget.role, index: index))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(roleColor(widget.role))
                Text(widget.name)
                    .font(.subheadline)
                    .foregroundColor(textDim)
            }

            Spacer(minLength: 8)

            Text(widget.typeTag)
                .font(.caption2.monospaced())
                .foregroundColor(textDim.opacity(0.75))
        }
    }

    private func roleLabel(_ role: WorkflowRole, index: Int) -> String {
        switch role {
        case .source: return String(localized: "Source")
        case .processor: return String(localized: "Processor \(index)")
        case .output: return String(localized: "Output")
        case .unknown: return String(localized: "Unavailable component")
        }
    }

    private func componentIcon(_ widget: WorkflowWidget) -> String {
        switch widget.typeTag {
        case "microphone": "mic.fill"
        case "provided_audio": "waveform"
        case "stt": "text.bubble"
        case "llm": "sparkles"
        case "insert": "keyboard"
        case "clipboard": "doc.on.clipboard"
        case "return_to_caller": "arrow.uturn.backward"
        case "ios_destination": "arrow.up.forward.app"
        case "shortcut": "square.2.layers.3d"
        default: "square.grid.2x2"
        }
    }

    private func roleColor(_ role: WorkflowRole) -> Color {
        switch role {
        case .source: amber
        case .processor: green
        case .output: Color(red: 196/255, green: 181/255, blue: 253/255)
        case .unknown: Color.red.opacity(0.75)
        }
    }

    private var workflowName: String {
        switch definition.id {
        case "wf.dictation" where definition.name == "Raw": String(localized: "Raw")
        case "wf.voice.polish" where definition.name == "Polish": String(localized: "Polish")
        case "wf.voice.formal" where definition.name == "Formal": String(localized: "Formal")
        case "wf.voice.translate" where definition.name == "Translate": String(localized: "Translate")
        default: definition.name
        }
    }

    private var workflowSymbol: String {
        switch definition.id {
        case "wf.dictation": "waveform"
        case "wf.voice.polish": "sparkles"
        case "wf.voice.formal": "briefcase"
        case "wf.voice.translate": "globe"
        default: "point.3.connected.trianglepath.dotted"
        }
    }

    @ViewBuilder
    private var workflowIcon: some View {
        let icon = definition.icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isKnownPreset, !icon.isEmpty,
           icon.unicodeScalars.contains(where: { $0.value > 127 }) {
            Text(icon)
                .font(.system(size: 19))
                .lineLimit(1)
        } else {
            Image(systemName: isKnownPreset || icon.isEmpty ? workflowSymbol : icon)
        }
    }

    private var isKnownPreset: Bool {
        switch definition.id {
        case "wf.dictation", "wf.voice.polish", "wf.voice.formal", "wf.voice.translate": true
        default: false
        }
    }
}
