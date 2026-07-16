import Foundation

extension ScenarioImporter {
    static func decodeVocabSnapshot(_ vocab: [String: Any]) throws -> VocabSnapshot {
        let books = try decodeVocabBooks(vocab["vocab_books"])
        let globalMountIDs: [String]
        if let rawValue = vocab["global_vocab_books"] {
            guard let entries = rawValue as? [Any] else {
                throw ImportError.invalidSection(
                    name: "vocab",
                    reason: "global_vocab_books must be an array of strings"
                )
            }
            let ids = entries.compactMap { $0 as? String }
            guard ids.count == entries.count else {
                throw ImportError.invalidSection(
                    name: "vocab",
                    reason: "global_vocab_books must contain only strings"
                )
            }
            globalMountIDs = ids
        } else {
            globalMountIDs = []
        }
        return VocabSnapshot(books: books, globalMountIDs: globalMountIDs)
    }

    static func decodeVocabBooks(_ rawValue: Any?) throws -> [VocabBook] {
        guard let rawValue else { return [] }
        guard let entries = rawValue as? [Any] else {
            throw ImportError.invalidSection(
                name: "vocab",
                reason: "vocab_books must be an array"
            )
        }
        let decoder = JSONDecoder()
        var books: [VocabBook] = []
        for (index, entry) in entries.enumerated() {
            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry),
                  let book = try? decoder.decode(VocabBook.self, from: data),
                  !book.id.isEmpty else {
                throw ImportError.invalidSection(
                    name: "vocab",
                    reason: "vocab_books[\(index)] is not a valid book with a non-empty id"
                )
            }
            books.append(book)
        }
        return books
    }

    /// Pre-Workbench desktop scenarios stored a map of `Mode` values instead
    /// of workflow components. This is the iOS contract equivalent of
    /// fonos-core's `widgets_from_legacy_modes`: every content-bearing custom
    /// mode becomes a `llm.{modeID}` processor overlay.
    static func decodeLegacyModeWidgets(_ rawValue: Any?) -> LegacyModeWidgetImport {
        switch rawValue {
        case nil, is NSNull:
            return LegacyModeWidgetImport(widgets: [], invalidCount: 0)
        case let modes as [String: Any]:
            var widgets: [WorkflowWidget] = []
            var invalidCount = 0
            for modeID in modes.keys.sorted() {
                guard !modeID.isEmpty,
                      let object = modes[modeID] as? [String: Any] else {
                    invalidCount += 1
                    continue
                }
                switch decodeLegacyModeWidget(id: modeID, object: object) {
                case .widget(let widget): widgets.append(widget)
                case .noLLMContent: break
                case .invalid: invalidCount += 1
                }
            }
            return LegacyModeWidgetImport(
                widgets: widgets,
                invalidCount: invalidCount
            )
        default:
            return LegacyModeWidgetImport(widgets: [], invalidCount: 1)
        }
    }

    static func decodeLegacyModeWidget(
        id: String,
        object: [String: Any]
    ) -> LegacyModeWidgetDecode {
        let name = legacyString(object, key: "name", default: "")
        let icon = legacyString(object, key: "icon", default: "⚙️")
        let system = legacyOptionalString(object, key: "system")
        let userTemplate = legacyOptionalString(object, key: "user_template")
        let temperature = legacyDouble(object, key: "temperature", default: 0.1)
        let maxTokens = legacyUnsignedInteger(object, key: "max_tokens", default: 4_096)
        let outputLanguage = legacyString(object, key: "output_language", default: "auto")
        let vocabBooks = legacyStringArray(object, key: "vocab_books", default: [])
        let modelProfile = legacyProfileID(object)
        let failurePolicy = legacyString(object, key: "failure_policy", default: "use_input")

        guard name.valid, icon.valid, system.valid, userTemplate.valid,
              temperature.valid, maxTokens.valid, outputLanguage.valid,
              vocabBooks.valid, modelProfile.valid, failurePolicy.valid,
              (0 ... 2).contains(temperature.value),
              (1 ... 128_000).contains(maxTokens.value),
              ["use_input", "fail_run"].contains(failurePolicy.value) else {
            return .invalid
        }

        // Matches fonos-core: these four already have canonical builtins;
        // `listen` is deliberately not skipped because users could customize
        // the old Listen mode and must be able to override llm.listen.
        if ["polish", "formal", "translate", "summarize"].contains(id) {
            return .noLLMContent
        }
        guard system.value != nil || userTemplate.value != nil else {
            return .noLLMContent
        }

        var props: [String: WorkflowJSONValue] = [
            "system": system.value.map(WorkflowJSONValue.string) ?? .null,
            "model_profile": .string(modelProfile.value),
            "temperature": .number(temperature.value),
            "max_tokens": .integer(maxTokens.value),
            "output_language": .string(outputLanguage.value),
            "vocab_books": .array(vocabBooks.value.map(WorkflowJSONValue.string)),
            "failure_policy": .string(failurePolicy.value)
        ]
        // A missing legacy Option means the LLM step's `{text}` default. Do
        // not encode JSON null here because iOS correctly rejects null for a
        // string template, whereas omission preserves the desktop meaning.
        if let userTemplate = userTemplate.value {
            props["user_template"] = .string(userTemplate)
        }
        return .widget(WorkflowWidget(
            id: "llm.\(id)",
            role: .processor,
            typeTag: "llm",
            name: name.value,
            icon: icon.value,
            props: .object(props),
            builtin: false
        ))
    }

    static func legacyString(
        _ object: [String: Any],
        key: String,
        default defaultValue: String
    ) -> (value: String, valid: Bool) {
        guard let rawValue = object[key] else { return (defaultValue, true) }
        guard let value = rawValue as? String else { return (defaultValue, false) }
        return (value, true)
    }

    static func legacyOptionalString(
        _ object: [String: Any],
        key: String
    ) -> (value: String?, valid: Bool) {
        guard let rawValue = object[key] else { return (nil, true) }
        if rawValue is NSNull { return (nil, true) }
        guard let value = rawValue as? String else { return (nil, false) }
        return (value, true)
    }

    static func legacyDouble(
        _ object: [String: Any],
        key: String,
        default defaultValue: Double
    ) -> (value: Double, valid: Bool) {
        guard let rawValue = object[key] else { return (defaultValue, true) }
        guard !(rawValue is Bool), let number = rawValue as? NSNumber else {
            return (defaultValue, false)
        }
        let value = number.doubleValue
        return (value, value.isFinite)
    }

    static func legacyUnsignedInteger(
        _ object: [String: Any],
        key: String,
        default defaultValue: Int64
    ) -> (value: Int64, valid: Bool) {
        guard let rawValue = object[key] else { return (defaultValue, true) }
        guard !(rawValue is Bool), let number = rawValue as? NSNumber else {
            return (defaultValue, false)
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= 0, value <= Double(UInt32.max) else {
            return (defaultValue, false)
        }
        return (Int64(value), true)
    }

    static func legacyStringArray(
        _ object: [String: Any],
        key: String,
        default defaultValue: [String]
    ) -> (value: [String], valid: Bool) {
        guard let rawValue = object[key] else { return (defaultValue, true) }
        guard let entries = rawValue as? [Any] else { return (defaultValue, false) }
        let values = entries.compactMap { $0 as? String }
        return values.count == entries.count ? (values, true) : (defaultValue, false)
    }

    /// `LegacyMode.model` named a raw model, not a profile, and is therefore
    /// intentionally ignored just like desktop. These aliases are accepted
    /// for later scenario producers that already carried a profile id.
    static func legacyProfileID(
        _ object: [String: Any]
    ) -> (value: String, valid: Bool) {
        if object["model_profile"] != nil {
            return legacyString(object, key: "model_profile", default: "")
        }
        return legacyString(object, key: "llm_profile", default: "")
    }

    static func upsert<T: Identifiable>(_ value: T, into values: inout [T])
    where T.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }

    static func assessSupport(
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
    static func firstRunnableMicrophone(
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

    static func isRunnableMicrophone(
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

    static func recordSelection(
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

    static func isSupported(_ widget: WorkflowWidget) -> Bool {
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
    static func mapProfile(_ entry: [String: Any]) -> ModelProfile? {
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
