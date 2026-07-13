import Foundation

/// Builds a shareable config bundle (ScenarioImporter shape) from the live
/// AppConfig + VocabStore. Bundles are keyless by default; API keys are pulled
/// from the Keychain only when explicitly requested, and are never stored at
/// rest (see ConfigSetStore).
enum ConfigBundleExporter {

    /// Look up a profile's API key. Injectable for tests; defaults to Keychain.
    typealias KeyLookup = @Sendable (_ profileID: String) -> String?
    static let defaultKeyLookup: KeyLookup = { id in
        (try? KeychainStore(service: "com.fonos.models").get(id)) ?? nil
    }

    /// Build a bundle from the current config. Includes every registered model
    /// profile (+ default assignments), the dictation defaults, and all vocab
    /// books with their global mounts. Notebook-scoped vocab mounts are omitted
    /// (notebook UUIDs are device-local).
    static func bundleJSON(config: AppConfig,
                           vocabStore: VocabStore,
                           name: String,
                           includeKeys: Bool,
                           keyLookup: KeyLookup = defaultKeyLookup) -> Data {
        var root: [String: Any] = ["version": 1, "name": name]

        let profiles: [[String: Any]] = config.modelProfiles.map { p in
            var d: [String: Any] = [
                "id": p.id, "name": p.name, "provider": p.provider,
                "model": p.modelID, "capabilities": p.capabilities
            ]
            if p.hasSTT { d["stt_api"] = p.effectiveSTTAPI }
            if let base = p.portableBaseURL, !base.isEmpty { d["base_url"] = base }
            if includeKeys, let key = keyLookup(p.id), !key.isEmpty { d["api_key"] = key }
            return d
        }
        root["models"] = [
            "profiles": profiles,
            "assignments": [
                "stt_profile": ModelProfileReference.normalized(config.sttProfile),
                "llm_profile": ModelProfileReference.normalized(config.llmProfile)
            ]
        ]

        let effectiveCatalog = config.workflowCatalog
        // Scenario files are a desktop contract, not a dump of iOS adapter
        // internals. Normalize the short-lived `return_to_caller` compatibility
        // output to desktop's registered `out.insert`. The receiving surface
        // still decides how insertion is performed, so iOS→iOS behavior is
        // unchanged while desktop imports remain executable.
        var workflowsForDesktop = config.workflows
        // SavedScenario currently has no active_voice_workflow field. Desktop
        // therefore continues to launch wf.dictation after an import. Project
        // the selected iOS microphone recipe onto that canonical id so a
        // selected Polish/custom recipe does not silently become Raw there.
        if let active = effectiveCatalog.workflow(id: config.activeVoiceWorkflowID),
           effectiveCatalog.widget(id: active.source)?.typeTag == "microphone" {
            // Keep the canonical dictation trigger surface. Copying a custom
            // recipe wholesale would duplicate its hotkey/triggers (the
            // original recipe is exported too) and could execute twice.
            let canonicalDictation = WorkflowCatalog.builtIn.workflow(id: "wf.dictation")
            var desktopDictation = workflowsForDesktop.first(where: { $0.id == "wf.dictation" })
                ?? canonicalDictation
                ?? active
            // Workflow overlays replace the desktop builtin wholesale. Keep
            // custom/imported usage triggers when present; otherwise restore
            // the canonical pill slot so an iOS projection cannot make the
            // default desktop dictation recipe disappear from the roller.
            if desktopDictation.hotkey.isEmpty,
               desktopDictation.triggers.isEmpty {
                desktopDictation.triggers = canonicalDictation?.triggers ?? []
            }
            desktopDictation.id = "wf.dictation"
            desktopDictation.name = active.name
            desktopDictation.icon = active.icon
            desktopDictation.source = active.source
            desktopDictation.processors = active.processors
            desktopDictation.outputs = active.outputs
            desktopDictation.builtin = true
            if let index = workflowsForDesktop.firstIndex(where: { $0.id == "wf.dictation" }) {
                workflowsForDesktop[index] = desktopDictation
            } else {
                workflowsForDesktop.append(desktopDictation)
            }
        }

        let exportedWorkflows = workflowsForDesktop.map { workflow in
            var workflow = workflow
            // These are iOS presets assembled from desktop components, not
            // shipped desktop builtins. Marking them builtin on desktop would
            // create undeletable recipes unknown to that release's catalog.
            if workflow.id.hasPrefix("wf.voice.") {
                workflow.builtin = false
            }
            var seen = Set<String>()
            workflow.outputs = workflow.outputs.compactMap { outputID in
                let normalized = effectiveCatalog.widget(id: outputID)?.typeTag == "return_to_caller"
                    ? "out.insert"
                    : outputID
                return seen.insert(normalized).inserted ? normalized : nil
            }
            return workflow
        }
        let exportedWidgets = config.widgets.filter { $0.typeTag != "return_to_caller" }

        var dictation: [String: Any] = [
            // Latest fonos-core scenario shape. These are overlays rather than
            // the effective builtin catalog, matching desktop snapshot_current.
            "user_modes": NSNull(),
            "user_workflows": jsonObjects(exportedWorkflows),
            "user_widgets": jsonObjects(exportedWidgets),
            // Forward-compatible identity hint for iOS↔iOS round trips. The
            // current desktop SavedScenario ignores unknown fields and uses
            // the projected wf.dictation topology above.
            "active_voice_workflow": config.activeVoiceWorkflowID,
            "dictation_mode": config.activeModeID,
            "translate_target": config.translateTargetLanguage
        ]
        // Keep the active workflow's reversible legacy mode in the compatibility
        // field when possible; desktop still reads dictation_mode during its
        // transition window.
        if let modeID = WorkflowMigration.legacyModeID(forWorkflowID: config.activeVoiceWorkflowID) {
            dictation["dictation_mode"] = modeID
        }
        root["dictation"] = dictation

        let books = vocabStore.books
        if !books.isEmpty, let encoded = try? JSONEncoder().encode(books),
           let bookDicts = try? JSONSerialization.jsonObject(with: encoded) as? [[String: Any]] {
            root["vocab"] = [
                "vocab_books": bookDicts,
                "global_vocab_books": vocabStore.mountedIDs(forKey: VocabStore.globalMountKey)
            ]
        }

        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func jsonObjects<T: Encodable>(_ values: [T]) -> [Any] {
        guard let data = try? JSONEncoder().encode(values),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return objects
    }

    /// Inject each profile's Keychain key into an existing keyless bundle
    /// (used when exporting a saved, at-rest keyless set WITH keys).
    static func injectingKeys(into bundleJSON: Data,
                              keyLookup: KeyLookup = defaultKeyLookup) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: bundleJSON) as? [String: Any],
              var models = root["models"] as? [String: Any],
              var profiles = models["profiles"] as? [[String: Any]] else {
            return bundleJSON
        }
        profiles = profiles.map { entry in
            var e = entry
            if let id = e["id"] as? String, let key = keyLookup(id), !key.isEmpty {
                e["api_key"] = key
            }
            return e
        }
        models["profiles"] = profiles
        root["models"] = models
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? bundleJSON
    }
}
