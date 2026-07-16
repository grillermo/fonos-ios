import Foundation

/// One-way compatibility bridge from the original iOS ModeConfig model to the
/// shared desktop workflow wire format. Schema 3 retires Mode persistence;
/// existing workflow/widget definitions are never overwritten.
enum WorkflowMigration {
    static let currentSchemaVersion = 3

    static func workflowID(forLegacyModeID modeID: String) -> String {
        switch modeID {
        case "raw": "wf.dictation"
        case "polish", "formal", "translate": "wf.voice.\(modeID)"
        default: "wf.custom-\(modeID)"
        }
    }

    static func legacyModeID(forWorkflowID workflowID: String) -> String? {
        switch workflowID {
        case "wf.dictation": "raw"
        case "wf.voice.polish": "polish"
        case "wf.voice.formal": "formal"
        case "wf.voice.translate": "translate"
        default:
            workflowID.hasPrefix("wf.custom-")
                ? String(workflowID.dropFirst("wf.custom-".count))
                : nil
        }
    }

    /// Materialize a legacy translate target on the workflow processor. The
    /// target belongs to `output_language` in schema 3; canonical builtin
    /// prompts are refreshed too, while custom prompt text remains untouched.
    @discardableResult
    static func synchronizeBuiltinTranslateTarget(
        _ target: String,
        in config: inout AppConfig
    ) -> Bool {
        let canonical = WorkflowCanonicalLLM.translate(targetLanguage: target)
        if let index = config.widgets.firstIndex(where: { $0.id == "llm.translate" }) {
            guard case .object(var props) = config.widgets[index].props else { return false }
            let oldProps = props
            if config.widgets[index].builtin {
                props["system"] = .string(canonical.system)
                props["user_template"] = .string(canonical.userTemplate)
            }
            props["output_language"] = .string(target)
            guard props != oldProps else { return false }
            config.widgets[index].props = .object(props)
            return true
        }

        guard var widget = config.workflowCatalog.widget(id: "llm.translate"),
              widget.builtin,
              case .object(var props) = widget.props else { return false }
        props["system"] = .string(canonical.system)
        props["user_template"] = .string(canonical.userTemplate)
        props["output_language"] = .string(target)
        widget.props = .object(props)
        config.widgets.append(widget)
        return true
    }

    /// Applies every missing migration artifact and returns whether the config
    /// changed. It is safe to call on every load; schema 3 never re-reads the
    /// retired Mode payload after the one-way upgrade.
    @discardableResult
    static func migrate(_ config: inout AppConfig) -> Bool {
        let sourceSchemaVersion = config.workflowSchemaVersion
        var changed = false
        if materializeDefaultSTTIfNeeded(
            in: &config,
            sourceSchemaVersion: sourceSchemaVersion
        ) { changed = true }
        if sourceSchemaVersion < currentSchemaVersion,
           materializeLegacyModes(in: &config) { changed = true }
        if repairSchemaOneDictation(
            in: &config,
            sourceSchemaVersion: sourceSchemaVersion
        ) { changed = true }
        if normalizeLegacyOutputs(in: &config) { changed = true }
        if finalizeWorkflowState(
            in: &config,
            sourceSchemaVersion: sourceSchemaVersion
        ) { changed = true }
        return changed
    }

    static func migrated(_ config: AppConfig) -> AppConfig {
        var config = config
        migrate(&config)
        return config
    }

    /// In the workflow model the STT language belongs to SttProps, not a
    /// parallel global runtime branch. Materialize a builtin overlay so an old
    /// non-auto language survives compilation. Imported overlays win.
    private static func materializeDefaultSTTIfNeeded(
        in config: inout AppConfig,
        sourceSchemaVersion: Int
    ) -> Bool {
        guard sourceSchemaVersion < 1,
              !config.widgets.contains(where: { $0.id == "stt.default" }),
              var defaultSTT = WorkflowCatalog.builtIn.widget(id: "stt.default"),
              case .object(var props) = defaultSTT.props else {
            return false
        }
        props["language"] = .string(config.sttLanguage)
        defaultSTT.props = .object(props)
        config.widgets.append(defaultSTT)
        return true
    }

    private static func materializeLegacyModes(in config: inout AppConfig) -> Bool {
        var changed = false
        for modeConfig in config.modeConfigs {
            let mode = resolvedMode(modeConfig, config: config)
            let processorResult = materializeProcessors(
                for: modeConfig,
                resolvedMode: mode,
                in: &config
            )
            if processorResult.changed { changed = true }

            let workflowID = workflowID(forLegacyModeID: modeConfig.id)
            guard !config.workflows.contains(where: { $0.id == workflowID }) else {
                continue
            }
            config.workflows.append(legacyWorkflow(
                id: workflowID,
                modeConfig: modeConfig,
                processors: processorResult.ids,
                recordMode: config.recordMode
            ))
            changed = true
        }
        return changed
    }

    private static func materializeProcessors(
        for modeConfig: ModeConfig,
        resolvedMode mode: Mode,
        in config: inout AppConfig
    ) -> (ids: [String], changed: Bool) {
        let component = safeComponent(modeConfig.id)
        var processors: [String] = []
        var changed = false

        let sttID: String
        if hasPerModeSTTSettings(modeConfig) {
            sttID = "stt.\(component)"
            if !config.widgets.contains(where: { $0.id == sttID }) {
                config.widgets.append(sttWidget(
                    id: sttID,
                    mode: modeConfig,
                    language: config.sttLanguage
                ))
                changed = true
            }
        } else {
            sttID = "stt.default"
        }
        processors.append(sttID)

        if mode.requiresLLM {
            let llmID = "llm.\(component)"
            if !config.widgets.contains(where: { $0.id == llmID }) {
                config.widgets.append(llmWidget(
                    id: llmID,
                    modeConfig: modeConfig,
                    mode: mode
                ))
                changed = true
            }
            processors.append(llmID)
        }
        return (processors, changed)
    }

    private static func legacyWorkflow(
        id workflowID: String,
        modeConfig: ModeConfig,
        processors: [String],
        recordMode: RecordMode
    ) -> WorkflowDefinition {
        WorkflowDefinition(
            id: workflowID,
            name: modeConfig.name,
            icon: modeConfig.icon,
            // This trigger is ignored on iOS but belongs to the shared desktop
            // definition. Overlays replace whole definitions, so omitting it
            // here would remove desktop's pill entry on the next round trip.
            triggers: workflowID == "wf.dictation" ? canonicalDictationTriggers : [],
            // Materialize the old surface setting into the recipe once; after
            // migration the source widget is authoritative.
            source: recordMode == .hold ? "src.mic-hold" : "src.mic-toggle",
            processors: processors,
            // `out.insert` is the shared desktop contract. On iOS the calling
            // surface owns its meaning. Legacy autoPaste never had a live iOS
            // reader, so it must not mint a private wire-format component.
            outputs: ["out.insert"],
            builtin: modeConfig.isBuiltIn
        )
    }

    /// Schema 1 was an unreleased iOS Flow build that materialized its own
    /// otherwise-canonical wf.dictation overlay with no triggers. Repair only
    /// that generated shape; imported desktop overlays remain authoritative.
    private static func repairSchemaOneDictation(
        in config: inout AppConfig,
        sourceSchemaVersion: Int
    ) -> Bool {
        guard sourceSchemaVersion == 1,
              let index = config.workflows.firstIndex(where: { $0.id == "wf.dictation" }),
              isGeneratedSchemaOneDictation(config.workflows[index], config: config) else {
            return false
        }
        config.workflows[index].triggers = canonicalDictationTriggers
        return true
    }

    /// Canonicalize configs written by the first iOS workflow prototype.
    /// `return_to_caller` was never part of fonos-core's registry; the platform
    /// adapter now interprets canonical `out.insert` instead.
    private static func normalizeLegacyOutputs(in config: inout AppConfig) -> Bool {
        let catalog = config.workflowCatalog
        var changed = false
        for index in config.workflows.indices {
            var seen = Set<String>()
            let normalized = config.workflows[index].outputs.compactMap { outputID in
                let output = catalog.widget(id: outputID)
                let canonicalID = output?.typeTag == "return_to_caller"
                    ? "out.insert"
                    : outputID
                return seen.insert(canonicalID).inserted ? canonicalID : nil
            }
            guard normalized != config.workflows[index].outputs else { continue }
            config.workflows[index].outputs = normalized
            changed = true
        }
        return changed
    }

    private static func finalizeWorkflowState(
        in config: inout AppConfig,
        sourceSchemaVersion: Int
    ) -> Bool {
        var changed = false
        if config.activeVoiceWorkflowID.isEmpty,
           sourceSchemaVersion < currentSchemaVersion {
            config.activeVoiceWorkflowID = workflowID(forLegacyModeID: config.activeModeID)
            changed = true
        }
        if config.workflowSchemaVersion < currentSchemaVersion {
            config.workflowSchemaVersion = currentSchemaVersion
            changed = true
        }
        return changed
    }

    private static func resolvedMode(_ modeConfig: ModeConfig, config: AppConfig) -> Mode {
        if modeConfig.id == "translate", case .translate = modeConfig.mode {
            return .translate(targetLanguage: config.translateTargetLanguage)
        }
        return modeConfig.mode
    }

    private static func hasPerModeSTTSettings(_ mode: ModeConfig) -> Bool {
        mode.sttModelID?.isEmpty == false
            || !mode.sttPrompt.isEmpty
            || mode.sttTemperature != 0
    }

    private static var canonicalDictationTriggers: [WorkflowTrigger] {
        WorkflowCatalog.builtIn.workflow(id: "wf.dictation")?.triggers
            ?? [.pillSlot(order: 0)]
    }

    private static func isGeneratedSchemaOneDictation(
        _ workflow: WorkflowDefinition,
        config: AppConfig
    ) -> Bool {
        guard workflow.builtin,
              workflow.hotkey.isEmpty,
              workflow.triggers.isEmpty,
              workflow.outputs == ["out.insert"],
              workflow.processors.count == 1,
              let source = config.workflowCatalog.widget(id: workflow.source),
              source.role == .source,
              source.typeTag == "microphone",
              let processor = config.workflowCatalog.widget(id: workflow.processors[0]),
              processor.role == .processor,
              processor.typeTag == "stt",
              let rawMode = config.modeConfigs.first(where: { $0.id == "raw" }),
              workflow.name == rawMode.name,
              workflow.icon == rawMode.icon else {
            return false
        }
        return true
    }

    private static func sttWidget(id: String, mode: ModeConfig, language: String) -> WorkflowWidget {
        WorkflowWidget(
            id: id,
            role: .processor,
            typeTag: "stt",
            name: "\(mode.name) · Transcription",
            icon: "waveform",
            props: .object([
                "model_profile": .string(mode.sttModelID ?? ""),
                "stt_prompt": .string(mode.sttPrompt),
                "vocab_books": .array([]),
                "temperature": .number(mode.sttTemperature),
                "language": .string(language)
            ]),
            builtin: mode.isBuiltIn
        )
    }

    private static func llmWidget(id: String, modeConfig: ModeConfig, mode: Mode) -> WorkflowWidget {
        let definition = WorkflowCanonicalLLM.definition(forLegacyMode: mode)
        let outputLanguage: String
        if case .translate(let targetLanguage) = mode {
            // The schema-3 config no longer persists
            // `translateTargetLanguage`, so the migrated workflow must own the
            // value in both its prompt and its desktop-compatible props.
            outputLanguage = targetLanguage
        } else {
            outputLanguage = modeConfig.outputLanguage
        }
        return WorkflowWidget(
            id: id,
            role: .processor,
            typeTag: "llm",
            name: modeConfig.name,
            icon: modeConfig.icon,
            props: WorkflowCanonicalLLM.props(
                definition: definition,
                modelProfile: modeConfig.llmModelID ?? "",
                outputLanguage: outputLanguage
            ),
            builtin: modeConfig.isBuiltIn
        )
    }

    /// Widget ids have a more constrained ecosystem than workflow ids. Encode
    /// non-portable UTF-8 bytes instead of dropping them, keeping ids stable and
    /// collision-free for custom modes.
    private static func safeComponent(_ value: String) -> String {
        var result = ""
        for byte in value.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "_%02X", byte)
            }
        }
        return result.isEmpty ? "unnamed" : result
    }
}
