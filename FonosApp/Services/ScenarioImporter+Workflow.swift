import Foundation

extension ScenarioImporter {
    static func applyDictation(
        _ dictation: [String: Any],
        priorActiveWorkflowID: String,
        to config: inout AppConfig,
        summary: inout ScenarioImportSummary
    ) {
        let imported = decodeDictation(dictation)
        if imported.legacyMode != nil || imported.translateTarget != nil {
            summary.dictationApplied = true
        }
        for widget in imported.widgets { upsert(widget, into: &config.widgets) }
        for workflow in imported.workflows { upsert(workflow, into: &config.workflows) }
        recordWorkflowImport(imported, summary: &summary)

        if imported.requiresMigration {
            // Imported overlays were upserted first, so the legacy bridge
            // fills only missing local recipes and never replaces desktop
            // definitions with the same id.
            WorkflowMigration.migrate(&config)
        }
        synchronizeImportedTranslateTarget(imported, in: &config)
        applyWorkflowSelection(
            imported,
            priorActiveWorkflowID: priorActiveWorkflowID,
            to: &config,
            summary: &summary
        )
    }

    static func applyWorkflowSelection(
        _ imported: DictationImport,
        priorActiveWorkflowID: String,
        to config: inout AppConfig,
        summary: inout ScenarioImportSummary
    ) {
        let requestedWorkflowID = imported.activeWorkflowID
            ?? (imported.hasImportedDictation ? "wf.dictation" : nil)
            ?? imported.mappedLegacyWorkflowID
            ?? priorActiveWorkflowID.nilIfEmpty
        let selectedWorkflow = firstRunnableMicrophone(
            catalog: config.workflowCatalog,
            config: config,
            importedActiveWorkflowID: imported.activeWorkflowID,
            hasImportedDictation: imported.hasImportedDictation,
            mappedLegacyWorkflowID: imported.mappedLegacyWorkflowID,
            priorActiveWorkflowID: priorActiveWorkflowID
        )
        config.activeVoiceWorkflowID = selectedWorkflow?.id ?? ""
        recordSelection(
            requestedWorkflowID: requestedWorkflowID,
            selectedWorkflow: selectedWorkflow,
            in: &summary
        )
    }

    static func applyVocab(
        _ vocab: [String: Any],
        to vocabStore: VocabStore,
        summary: inout ScenarioImportSummary
    ) throws {
        let snapshot = try decodeVocabSnapshot(vocab)
        vocabStore.replace(books: snapshot.books, globalMountIDs: snapshot.globalMountIDs)
        summary.vocabBooksImported = snapshot.books.count
        summary.vocabApplied = true
    }

    /// Counts what an import would change, without mutating (for the preview).
    static func summarize(_ root: [String: Any]) throws -> ScenarioImportSummary {
        var summary = ScenarioImportSummary(name: root["name"] as? String ?? "")
        if let models = root["models"] as? [String: Any] {
            summarizeModels(models, in: &summary)
        }
        if let dictation = root["dictation"] as? [String: Any] {
            summarizeDictation(dictation, root: root, in: &summary)
        }
        if let vocab = root["vocab"] as? [String: Any] {
            summary.vocabBooksImported = try decodeVocabSnapshot(vocab).books.count
            summary.vocabApplied = true
        }
        appendSkippedRootSections(root, to: &summary)
        return summary
    }

    static func summarizeModels(
        _ models: [String: Any],
        in summary: inout ScenarioImportSummary
    ) {
        for entry in models["profiles"] as? [[String: Any]] ?? [] {
            guard (entry["id"] as? String)?.isEmpty == false else { continue }
            summary.importedProfiles += 1
            let hasKey = (entry["api_key"] as? String).map { !$0.isEmpty } ?? false
            if !hasKey { summary.profilesNeedingKeys += 1 }
        }
        guard let assignments = models["assignments"] as? [String: Any] else { return }
        summary.sttProfileSet = assignments["stt_profile"] is String
        summary.llmProfileSet = assignments["llm_profile"] is String
    }

    static func summarizeDictation(
        _ dictation: [String: Any],
        root: [String: Any],
        in summary: inout ScenarioImportSummary
    ) {
        let imported = decodeDictation(dictation)
        summary.dictationApplied = imported.legacyMode != nil
            || imported.translateTarget != nil
            || imported.activeWorkflowID != nil
        recordWorkflowImport(imported, summary: &summary)

        // Preview selection against imported overlays plus iOS builtins. Apply
        // also considers the recipient's prior active recipe before fallback.
        let previewConfig = makePreviewConfig(root: root, imported: imported)
        let requestedWorkflowID = imported.activeWorkflowID
            ?? (imported.hasImportedDictation ? "wf.dictation" : nil)
            ?? imported.mappedLegacyWorkflowID
        let selectedWorkflow = firstRunnableMicrophone(
            catalog: previewConfig.workflowCatalog,
            config: previewConfig,
            importedActiveWorkflowID: imported.activeWorkflowID,
            hasImportedDictation: imported.hasImportedDictation,
            mappedLegacyWorkflowID: imported.mappedLegacyWorkflowID,
            priorActiveWorkflowID: ""
        )
        recordSelection(
            requestedWorkflowID: requestedWorkflowID,
            selectedWorkflow: selectedWorkflow,
            in: &summary
        )
    }

    static func makePreviewConfig(
        root: [String: Any],
        imported: DictationImport
    ) -> AppConfig {
        var config = AppConfig()
        if let models = root["models"] as? [String: Any] {
            config.modelProfiles = (models["profiles"] as? [[String: Any]] ?? [])
                .compactMap(mapProfile)
            if let assignments = models["assignments"] as? [String: Any] {
                config.sttProfile = ModelProfileReference.normalized(
                    assignments["stt_profile"] as? String ?? ""
                )
                config.llmProfile = ModelProfileReference.normalized(
                    assignments["llm_profile"] as? String ?? ""
                )
            }
        }
        config.widgets = imported.widgets
        config.workflows = imported.workflows
        if imported.requiresMigration { WorkflowMigration.migrate(&config) }
        synchronizeImportedTranslateTarget(imported, in: &config)
        return config
    }

    static func synchronizeImportedTranslateTarget(
        _ imported: DictationImport,
        in config: inout AppConfig
    ) {
        guard let target = imported.translateTarget,
              !imported.widgets.contains(where: { $0.id == "llm.translate" }) else { return }
        // Schema 3 no longer persists translateTargetLanguage. Put the value
        // on the processor itself so import, runtime, and the next export all
        // observe the same workflow-owned target.
        WorkflowMigration.synchronizeBuiltinTranslateTarget(target, in: &config)
    }

    static func decodeDictation(_ dictation: [String: Any]) -> DictationImport {
        let decodedWidgets: ([WorkflowWidget], invalid: Int) = decodeEntries(dictation["user_widgets"])
        let legacyWidgets = decodeLegacyModeWidgets(dictation["user_modes"])
        var widgets = decodedWidgets.0
        // Desktop applies current overlays first, then its legacy-mode bridge.
        // Preserve that ordering so a legacy `listen` customization replaces
        // the same-id current/builtin component exactly as fonos-core does.
        for widget in legacyWidgets.widgets { upsert(widget, into: &widgets) }
        let workflows: ([WorkflowDefinition], invalid: Int) = decodeEntries(dictation["user_workflows"])
        let legacyMode = (dictation["dictation_mode"] as? String)?.nilIfEmpty
        return DictationImport(
            activeWorkflowID: (dictation["active_voice_workflow"] as? String)?.nilIfEmpty,
            legacyMode: legacyMode,
            translateTarget: (dictation["translate_target"] as? String)?.nilIfEmpty,
            widgets: widgets,
            invalidWidgetCount: decodedWidgets.invalid + legacyWidgets.invalidCount,
            workflows: workflows.0,
            invalidWorkflowCount: workflows.invalid,
            requiresMigration: legacyMode != nil
                || !legacyWidgets.widgets.isEmpty
                || dictation["user_widgets"] != nil
                || dictation["user_workflows"] != nil
        )
    }

    static func recordWorkflowImport(
        _ imported: DictationImport,
        summary: inout ScenarioImportSummary
    ) {
        summary.importedWidgets = imported.widgets.count
        summary.importedWorkflows = imported.workflows.count
        let support = assessSupport(widgets: imported.widgets, workflows: imported.workflows)
        summary.unsupportedWidgets = support.unsupportedWidgets + imported.invalidWidgetCount
        summary.unsupportedWorkflows = support.unsupportedWorkflows + imported.invalidWorkflowCount
        summary.adaptedWorkflows = support.adaptedWorkflows
    }

    static func appendSkippedRootSections(
        _ root: [String: Any],
        to summary: inout ScenarioImportSummary
    ) {
        if root["speech"] != nil { summary.skippedSections.append("speech") }
        if root["hotkeys"] != nil { summary.skippedSections.append("hotkeys") }
    }

    static func decodeEntries<T: Decodable>(_ rawValue: Any?) -> ([T], invalid: Int) {
        guard let rawValue else { return ([], 0) }
        guard let entries = rawValue as? [Any] else { return ([], 1) }
        var values: [T] = []
        var invalid = 0
        let decoder = JSONDecoder()
        for entry in entries {
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry),
                  let value = try? decoder.decode(T.self, from: data) else {
                invalid += 1
                continue
            }
            values.append(value)
        }
        return (values, invalid)
    }

}
