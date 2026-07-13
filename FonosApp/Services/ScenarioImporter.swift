import Foundation

/// What a scenario/config import changed (or would change, for a preview).
struct ScenarioImportSummary: Equatable {
    var name: String = ""
    var importedProfiles: Int = 0
    var sttProfileSet = false
    var llmProfileSet = false
    var dictationApplied = false
    var vocabBooksImported: Int = 0
    var importedWorkflows: Int = 0
    var importedWidgets: Int = 0
    /// Definitions retained for round-trip compatibility but not executable by
    /// the current iOS registry. Invalid entries are included in these counts.
    var unsupportedWorkflows: Int = 0
    var unsupportedWidgets: Int = 0
    /// Desktop `insert` outputs are executable through an iOS surface adapter
    /// (main app returns the value; keyboard insertion remains explicit).
    var adaptedWorkflows: Int = 0
    /// Import selection never leaves the app pointing at a missing or invalid
    /// recipe. When the requested recipe cannot run, this records the runnable
    /// microphone recipe selected instead.
    var activeWorkflowAdjusted = false
    var selectedWorkflowID: String = ""
    var selectedWorkflowName: String = ""
    /// Every effective microphone recipe failed iOS validation. Definitions
    /// are still retained for round-trip compatibility, but selection is
    /// cleared so recording cannot start against a dangling id.
    var noRunnableWorkflow = false
    /// Profiles arriving without an embedded API key — the recipient must enter
    /// one for these if the provider needs it.
    var profilesNeedingKeys: Int = 0
    var skippedSections: [String] = []
}

private struct DictationImport {
    let activeWorkflowID: String?
    let legacyMode: String?
    let translateTarget: String?
    let widgets: [WorkflowWidget]
    let invalidWidgetCount: Int
    let workflows: [WorkflowDefinition]
    let invalidWorkflowCount: Int
    let hasLegacyUserModes: Bool
    let requiresMigration: Bool

    var hasImportedDictation: Bool {
        workflows.contains { $0.id == "wf.dictation" }
    }

    var mappedLegacyWorkflowID: String? {
        legacyMode.map(WorkflowMigration.workflowID(forLegacyModeID:))
    }
}

private struct WorkflowSupportAssessment {
    let unsupportedWidgets: Int
    let unsupportedWorkflows: Int
    let adaptedWorkflows: Int
}

/// Imports desktop-exported scenario files (fonos-core scenarios.rs
/// SavedScenario, key-stripped) so a desktop-tuned setup lands on the phone
/// in one step. Import side only — iOS never exports scenarios.
///
/// Applied sections: models (profiles + stt/llm assignments), dictation
/// (mode + translate target), vocab (books + global mounts). Skipped:
/// speech (voice output is P2) and hotkeys (no global hotkeys on iOS).
enum ScenarioImporter {

    enum ImportError: LocalizedError {
        case notAScenario

        var errorDescription: String? {
            "This file is not a Fonos scenario export."
        }
    }

    /// Writes an imported profile's API key. Injectable for tests; defaults to
    /// the models Keychain (never UserDefaults).
    typealias KeyWriter = @Sendable (_ profileID: String, _ apiKey: String) -> Void
    static let defaultKeyWriter: KeyWriter = { id, key in
        try? KeychainStore(service: "com.fonos.models").set(key, forKey: id)
    }

    /// Dry-run: what an import of `data` would change, without mutating anything.
    /// Used by the import preview sheet.
    static func preview(data: Data) throws -> ScenarioImportSummary {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notAScenario
        }
        return summarize(root)
    }

    /// Parses `data` and applies the iOS-relevant sections. Returns the
    /// updated config plus a summary; vocab changes go into `vocabStore`, and
    /// any embedded API keys go through `keyWriter` (Keychain by default).
    static func apply(data: Data,
                      to config: AppConfig,
                      vocabStore: VocabStore,
                      keyWriter: KeyWriter = defaultKeyWriter) throws -> (AppConfig, ScenarioImportSummary) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notAScenario
        }

        let priorActiveWorkflowID = config.activeVoiceWorkflowID
        var config = config
        var summary = ScenarioImportSummary(name: root["name"] as? String ?? "")

        if let models = root["models"] as? [String: Any] {
            applyModels(models, to: &config, summary: &summary, keyWriter: keyWriter)
        }
        if let dictation = root["dictation"] as? [String: Any] {
            applyDictation(
                dictation,
                priorActiveWorkflowID: priorActiveWorkflowID,
                to: &config,
                summary: &summary
            )
        }
        if let vocab = root["vocab"] as? [String: Any] {
            applyVocab(vocab, to: vocabStore, summary: &summary)
        }
        appendSkippedRootSections(root, to: &summary)
        return (config, summary)
    }

    private static func applyModels(
        _ models: [String: Any],
        to config: inout AppConfig,
        summary: inout ScenarioImportSummary,
        keyWriter: KeyWriter
    ) {
        for entry in models["profiles"] as? [[String: Any]] ?? [] {
            guard let profile = mapProfile(entry) else { continue }
            upsert(profile, into: &config.modelProfiles)
            summary.importedProfiles += 1
            if let key = entry["api_key"] as? String, !key.isEmpty {
                keyWriter(profile.id, key)
            } else {
                summary.profilesNeedingKeys += 1
            }
        }
        guard let assignments = models["assignments"] as? [String: Any] else { return }
        if let stt = assignments["stt_profile"] as? String {
            config.sttProfile = ModelProfileReference.normalized(stt)
            summary.sttProfileSet = true
        }
        if let llm = assignments["llm_profile"] as? String {
            config.llmProfile = ModelProfileReference.normalized(llm)
            summary.llmProfileSet = true
        }
    }

    private static func applyDictation(
        _ dictation: [String: Any],
        priorActiveWorkflowID: String,
        to config: inout AppConfig,
        summary: inout ScenarioImportSummary
    ) {
        let imported = decodeDictation(dictation)
        if let mode = imported.legacyMode {
            config.activeModeID = mode
            summary.dictationApplied = true
        }
        if let target = imported.translateTarget {
            config.translateTargetLanguage = target
            summary.dictationApplied = true
        }
        if imported.hasLegacyUserModes {
            summary.skippedSections.append("dictation.user_modes (legacy)")
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
        if let target = imported.translateTarget,
           !imported.widgets.contains(where: { $0.id == "llm.translate" }) {
            WorkflowMigration.synchronizeBuiltinTranslateTarget(target, in: &config)
        }
        applyWorkflowSelection(
            imported,
            priorActiveWorkflowID: priorActiveWorkflowID,
            to: &config,
            summary: &summary
        )
    }

    private static func applyWorkflowSelection(
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

    private static func applyVocab(
        _ vocab: [String: Any],
        to vocabStore: VocabStore,
        summary: inout ScenarioImportSummary
    ) {
        for object in vocab["vocab_books"] as? [[String: Any]] ?? [] {
            guard let bookData = try? JSONSerialization.data(withJSONObject: object),
                  let book = try? JSONDecoder().decode(VocabBook.self, from: bookData),
                  !book.id.isEmpty else { continue }
            vocabStore.upsert(book)
            summary.vocabBooksImported += 1
        }
        for id in vocab["global_vocab_books"] as? [String] ?? [] {
            vocabStore.setMounted(true, bookID: id, forKey: VocabStore.globalMountKey)
        }
    }

    /// Counts what an import would change, without mutating (for the preview).
    private static func summarize(_ root: [String: Any]) -> ScenarioImportSummary {
        var summary = ScenarioImportSummary(name: root["name"] as? String ?? "")
        if let models = root["models"] as? [String: Any] {
            summarizeModels(models, in: &summary)
        }
        if let dictation = root["dictation"] as? [String: Any] {
            summarizeDictation(dictation, root: root, in: &summary)
        }
        if let vocab = root["vocab"] as? [String: Any] {
            summary.vocabBooksImported = (vocab["vocab_books"] as? [[String: Any]] ?? [])
                .filter { ($0["id"] as? String)?.isEmpty == false }.count
        }
        appendSkippedRootSections(root, to: &summary)
        return summary
    }

    private static func summarizeModels(
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

    private static func summarizeDictation(
        _ dictation: [String: Any],
        root: [String: Any],
        in summary: inout ScenarioImportSummary
    ) {
        let imported = decodeDictation(dictation)
        summary.dictationApplied = imported.legacyMode != nil
            || imported.translateTarget != nil
            || imported.activeWorkflowID != nil
        if imported.hasLegacyUserModes {
            summary.skippedSections.append("dictation.user_modes (legacy)")
        }
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

    private static func makePreviewConfig(
        root: [String: Any],
        imported: DictationImport
    ) -> AppConfig {
        var config = AppConfig()
        config.activeModeID = imported.legacyMode ?? config.activeModeID
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
        return config
    }

    private static func decodeDictation(_ dictation: [String: Any]) -> DictationImport {
        let widgets: ([WorkflowWidget], invalid: Int) = decodeEntries(dictation["user_widgets"])
        let workflows: ([WorkflowDefinition], invalid: Int) = decodeEntries(dictation["user_workflows"])
        let legacyMode = (dictation["dictation_mode"] as? String)?.nilIfEmpty
        return DictationImport(
            activeWorkflowID: (dictation["active_voice_workflow"] as? String)?.nilIfEmpty,
            legacyMode: legacyMode,
            translateTarget: (dictation["translate_target"] as? String)?.nilIfEmpty,
            widgets: widgets.0,
            invalidWidgetCount: widgets.invalid,
            workflows: workflows.0,
            invalidWorkflowCount: workflows.invalid,
            hasLegacyUserModes: hasLegacyUserModes(dictation["user_modes"]),
            requiresMigration: legacyMode != nil
                || dictation["user_widgets"] != nil
                || dictation["user_workflows"] != nil
        )
    }

    private static func recordWorkflowImport(
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

    private static func appendSkippedRootSections(
        _ root: [String: Any],
        to summary: inout ScenarioImportSummary
    ) {
        if root["speech"] != nil { summary.skippedSections.append("speech") }
        if root["hotkeys"] != nil { summary.skippedSections.append("hotkeys") }
    }

    private static func decodeEntries<T: Decodable>(_ rawValue: Any?) -> ([T], invalid: Int) {
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

    private static func hasLegacyUserModes(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            false
        case let object as [String: Any]:
            !object.isEmpty
        case let array as [Any]:
            !array.isEmpty
        default:
            true
        }
    }

    private static func upsert<T: Identifiable>(_ value: T, into values: inout [T])
    where T.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }

    private static func assessSupport(
        widgets: [WorkflowWidget],
        workflows: [WorkflowDefinition]
    ) -> WorkflowSupportAssessment {
        let catalog = WorkflowCatalog.effective(userWidgets: widgets, userWorkflows: workflows)
        let unsupportedWidgets = widgets.filter { !isSupported($0) }.count
        let engine = VoiceWorkflowEngine()
        var unsupportedWorkflows = 0
        var adaptedWorkflows = 0

        for workflow in workflows {
            guard (try? engine.validate(definition: workflow, catalog: catalog)) != nil else {
                unsupportedWorkflows += 1
                continue
            }
            if workflow.outputs.contains(where: { catalog.widget(id: $0)?.typeTag == "insert" }) {
                adaptedWorkflows += 1
            }
        }
        return WorkflowSupportAssessment(
            unsupportedWidgets: unsupportedWidgets,
            unsupportedWorkflows: unsupportedWorkflows,
            adaptedWorkflows: adaptedWorkflows
        )
    }

    /// Selection order mirrors the product contract for a voice surface:
    /// explicit iOS round-trip identity, imported desktop wf.dictation, mapped
    /// legacy preference, the recipient's prior active recipe, then the first
    /// runnable microphone recipe.
    private static func firstRunnableMicrophone(
        catalog: WorkflowCatalog,
        config: AppConfig,
        importedActiveWorkflowID: String?,
        hasImportedDictation: Bool,
        mappedLegacyWorkflowID: String?,
        priorActiveWorkflowID: String
    ) -> WorkflowDefinition? {
        var preferredIDs: [String] = []
        if let importedActiveWorkflowID { preferredIDs.append(importedActiveWorkflowID) }
        if hasImportedDictation { preferredIDs.append("wf.dictation") }
        if let mappedLegacyWorkflowID { preferredIDs.append(mappedLegacyWorkflowID) }
        if !priorActiveWorkflowID.isEmpty { preferredIDs.append(priorActiveWorkflowID) }

        var visited = Set<String>()
        for id in preferredIDs where visited.insert(id).inserted {
            guard let workflow = catalog.workflow(id: id),
                  isRunnableMicrophone(workflow, catalog: catalog, config: config) else { continue }
            return workflow
        }
        return catalog.workflows.first { workflow in
            visited.insert(workflow.id).inserted
                && isRunnableMicrophone(workflow, catalog: catalog, config: config)
        }
    }

    private static func isRunnableMicrophone(
        _ workflow: WorkflowDefinition,
        catalog: WorkflowCatalog,
        config: AppConfig
    ) -> Bool {
        guard let validation = try? VoiceWorkflowOperationalValidator.validateMicrophone(
            definition: workflow,
            catalog: catalog,
            config: config
        ) else { return false }
        return validation.sourceKind == .microphone
    }

    private static func recordSelection(
        requestedWorkflowID: String?,
        selectedWorkflow: WorkflowDefinition?,
        in summary: inout ScenarioImportSummary
    ) {
        summary.selectedWorkflowID = selectedWorkflow?.id ?? ""
        summary.selectedWorkflowName = selectedWorkflow?.name ?? ""
        summary.noRunnableWorkflow = selectedWorkflow == nil
        summary.activeWorkflowAdjusted = requestedWorkflowID.map { requested in
            selectedWorkflow?.id != requested
        } ?? false
    }

    private static func isSupported(_ widget: WorkflowWidget) -> Bool {
        switch widget.role {
        case .source:
            return ["microphone", "provided_audio"].contains(widget.typeTag)
        case .processor:
            return ["stt", "llm"].contains(widget.typeTag)
        case .output:
            return ["insert", "return_to_caller", "clipboard"].contains(widget.typeTag)
        case .unknown:
            return false
        }
    }

    /// Maps a desktop profile JSON entry ({id, name, provider, model,
    /// base_url, capabilities}) onto the iOS ModelProfile shape.
    private static func mapProfile(_ entry: [String: Any]) -> ModelProfile? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        return ModelProfile(
            id: id,
            name: entry["name"] as? String ?? id,
            provider: entry["provider"] as? String ?? "custom",
            modelID: entry["model"] as? String
                ?? entry["model_id"] as? String
                ?? "",
            baseURL: entry["base_url"] as? String,
            capabilities: entry["capabilities"] as? [String] ?? ["llm"],
            sttAPI: entry["stt_api"] as? String
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
