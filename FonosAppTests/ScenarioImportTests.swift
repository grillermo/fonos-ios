// P1-2 (docs/ROADMAP.md): import desktop-exported scenario files so a
// desktop-tuned setup lands on the phone in one step. Sections: models /
// dictation / vocab are applied; speech and hotkeys are iOS-irrelevant and
// skipped. Shapes mirror fonos-core scenarios.rs (SavedScenario).
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/ScenarioImportTests

import Testing
import Foundation
@testable import FonosApp

private let sampleScenario = """
{
  "id": "scn-1", "name": "Home Lab", "created_at": "1750000000",
  "models": {
    "profiles": [
      {"id": "stt1", "name": "ASR", "provider": "omlx", "model": "Qwen3-ASR-1.7B",
       "base_url": "http://192.168.1.5:8000", "capabilities": ["stt"], "stt_api": "chat"},
      {"id": "llm1", "name": "Chat", "provider": "omlx", "model": "Qwen3-8B-Instruct",
       "base_url": "http://192.168.1.5:8000", "capabilities": ["llm"]}
    ],
    "assignments": {"stt_profile": "stt1", "llm_profile": "llm1", "tts_profile": "tts9"}
  },
  "dictation": {"user_modes": {}, "dictation_mode": "polish", "translate_target": "French"},
  "speech": {"listen_mode": "summary"},
  "vocab": {
    "vocab_books": [{"id": "tech", "name": "Tech", "terms": ["Kubernetes"],
                     "rules": [{"from": "my sequel", "to": "MySQL"}]}],
    "global_vocab_books": ["tech"]
  },
  "hotkeys": {"hotkey_dictation": "Ctrl+Space"}
}
""".data(using: .utf8)!

private let workflowScenario = """
{
  "id": "workflow-scenario", "name": "Desktop workflows",
  "dictation": {
    "user_modes": null,
    "dictation_mode": "polish",
    "translate_target": "German",
    "user_widgets": [
      {"id":"stt.mobile","role":"processor","type_tag":"stt","name":"Mobile STT",
       "props":{"model_profile":"stt1","language":"English","future":{"nested":[1,true,"x"]}}},
      {"id":"out.desktop-panel","role":"output","type_tag":"panel","name":"Panel",
       "props":{"markdown":true}},
      {"id":"broken-widget"}
    ],
    "user_workflows": [
      {"id":"wf.mobile","name":"Mobile","source":"src.mic-hold",
       "processors":["stt.mobile"],"outputs":["out.insert"],
       "triggers":[{"kind":"pill_slot","order":20}]},
      {"id":"wf.desktop-panel","name":"Desktop panel","source":"src.mic-hold",
       "processors":["stt.mobile"],"outputs":["out.desktop-panel"]},
      {"id":"broken-workflow"}
    ]
  }
}
""".data(using: .utf8)!

private let overlaidDictationScenario = """
{
  "id":"latest-dictation", "name":"Latest dictation",
  "dictation": {
    "dictation_mode":"polish",
    "user_workflows":[
      {"id":"wf.dictation","name":"Dictation · Polish","source":"src.mic-hold",
       "processors":["stt.default","llm.polish"],"outputs":["out.insert"],"builtin":true}
    ],
    "user_widgets":[]
  }
}
""".data(using: .utf8)!

private func freshStore() -> VocabStore {
    let name = "scenario-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return VocabStore(defaults: d)
}

struct ScenarioImportTests {

    @Test("imports model profiles with mapped fields and assignments")
    func importsModelProfiles() throws {
        let (config, summary) = try ScenarioImporter.apply(
            data: sampleScenario, to: AppConfig(), vocabStore: freshStore())

        let stt = config.modelProfiles.first { $0.id == "stt1" }
        #expect(stt?.name == "ASR")
        #expect(stt?.provider == "omlx")
        #expect(stt?.modelID == "Qwen3-ASR-1.7B")
        #expect(stt?.baseURL == "http://192.168.1.5:8000")
        #expect(stt?.hasSTT == true)
        #expect(stt?.effectiveSTTAPI == "chat")
        #expect(config.sttProfile == "stt1")
        #expect(config.llmProfile == "llm1")
        #expect(summary.importedProfiles == 2)
    }

    @Test("updates an existing profile instead of duplicating it")
    func updatesExistingProfile() throws {
        var base = AppConfig()
        base.modelProfiles = [ModelProfile(id: "stt1", name: "Old", provider: "omlx",
                                           modelID: "old", baseURL: "http://old",
                                           capabilities: ["stt"])]
        let (config, _) = try ScenarioImporter.apply(
            data: sampleScenario, to: base, vocabStore: freshStore())
        #expect(config.modelProfiles.filter { $0.id == "stt1" }.count == 1)
        #expect(config.modelProfiles.first { $0.id == "stt1" }?.name == "ASR")
    }

    @Test("empty desktop model assignments clear stale phone defaults")
    func emptyAssignmentsClearDefaults() throws {
        var base = AppConfig()
        base.sttProfile = "old-stt"
        base.llmProfile = "old-llm"
        let data = """
        {"models":{"profiles":[],"assignments":{"stt_profile":"","llm_profile":""}}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: base, vocabStore: freshStore())

        #expect(config.sttProfile.isEmpty)
        #expect(config.llmProfile.isEmpty)
        #expect(summary.sttProfileSet)
        #expect(summary.llmProfileSet)
        let preview = try ScenarioImporter.preview(data: data)
        #expect(preview.sttProfileSet)
        #expect(preview.llmProfileSet)
    }

    @Test("applies dictation mode and translate target")
    func appliesDictation() throws {
        let (config, _) = try ScenarioImporter.apply(
            data: sampleScenario, to: AppConfig(), vocabStore: freshStore())
        #expect(config.activeVoiceWorkflowID == "wf.voice.polish")
        #expect(config.activeVoiceWorkflow?.processors == ["stt.default", "llm.polish"])
        #expect(config.workflowCatalog.widget(id: "llm.translate")?
            .props["output_language"]?.stringValue == "French")
        #expect(config.workflowCatalog.widget(id: "llm.translate")?
            .props["user_template"]?.stringValue?.contains("to French") == true)
    }

    @Test("legacy translate target is persisted on the schema-3 processor")
    func legacyTranslateTargetRefreshesProcessor() throws {
        var base = WorkflowMigration.migrated(AppConfig())
        base.translateTargetLanguage = "English"
        let data = """
        {"dictation":{"dictation_mode":"translate","translate_target":"French"}}
        """.data(using: .utf8)!

        let (config, _) = try ScenarioImporter.apply(
            data: data, to: base, vocabStore: freshStore())

        #expect(config.workflowCatalog.widget(id: "llm.translate")?
            .props["user_template"]?.stringValue?.contains("to French") == true)
        #expect(config.workflowCatalog.widget(id: "llm.translate")?
            .props["output_language"]?.stringValue == "French")

        let restored = try JSONDecoder().decode(
            AppConfig.self,
            from: JSONEncoder().encode(config)
        )
        #expect(restored.workflowCatalog.widget(id: "llm.translate")?
            .props["output_language"]?.stringValue == "French")

        let exported = ConfigBundleExporter.bundleJSON(
            config: restored,
            vocabStore: freshStore(),
            name: "Translated",
            includeKeys: false,
            keyLookup: { _ in nil }
        )
        let root = try #require(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        let dictation = try #require(root["dictation"] as? [String: Any])
        #expect(dictation["translate_target"] as? String == "French")
    }

    @Test("legacy translate target updates custom output language without replacing its prompt")
    func legacyTranslateTargetPreservesCustomPrompt() throws {
        var base = AppConfig()
        base.workflowSchemaVersion = WorkflowMigration.currentSchemaVersion
        base.widgets = [WorkflowWidget(
            id: "llm.translate",
            role: .processor,
            typeTag: "llm",
            name: "My translator",
            props: .object([
                "system": .string("Keep this custom system prompt"),
                "user_template": .string("CUSTOM::{text}"),
                "output_language": .string("Italian"),
                "temperature": .number(0.7)
            ]),
            builtin: false
        )]
        let data = #"{"dictation":{"translate_target":"French"}}"#.data(using: .utf8)!

        let (config, _) = try ScenarioImporter.apply(
            data: data,
            to: base,
            vocabStore: freshStore()
        )
        let translated = try #require(config.workflowCatalog.widget(id: "llm.translate"))

        #expect(translated.props["system"]?.stringValue == "Keep this custom system prompt")
        #expect(translated.props["user_template"]?.stringValue == "CUSTOM::{text}")
        #expect(translated.props["temperature"]?.doubleValue == 0.7)
        #expect(translated.props["output_language"]?.stringValue == "French")
        #expect(!translated.builtin)
    }

    @Test("pre-Workbench user_modes become usable LLM widget overlays")
    func legacyUserModesBecomeWidgets() throws {
        let data = """
        {"dictation":{"user_modes":{
          "custom":{
            "name":"Legacy editor","icon":"🧰","system":"Rewrite safely.",
            "user_template":"Input: {text}","temperature":0.4,"max_tokens":2048,
            "output_language":"French","vocab_books":["tech"],
            "model":"raw-model-id-is-not-a-profile","model_profile":"llm-profile",
            "failure_policy":"fail_run"
          },
          "listen":{"name":"My Listen","system":"Make a spoken briefing."},
          "summarize":{"name":"Old builtin","system":"Must not replace the builtin."},
          "plain":{"name":"No LLM content"},
          "broken":{"system":"x","max_tokens":"many"}
        }}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: freshStore())
        let custom = try #require(config.widgets.first { $0.id == "llm.custom" })
        #expect(custom.name == "Legacy editor")
        #expect(custom.icon == "🧰")
        #expect(custom.props["system"]?.stringValue == "Rewrite safely.")
        #expect(custom.props["user_template"]?.stringValue == "Input: {text}")
        #expect(custom.props["temperature"]?.doubleValue == 0.4)
        #expect(custom.props["max_tokens"]?.intValue == 2048)
        #expect(custom.props["output_language"]?.stringValue == "French")
        #expect(custom.props["vocab_books"]?.stringArray == ["tech"])
        #expect(custom.props["model_profile"]?.stringValue == "llm-profile")
        #expect(custom.props["failure_policy"]?.stringValue == "fail_run")
        #expect(config.widgets.contains { $0.id == "llm.listen" && $0.name == "My Listen" })
        #expect(!config.widgets.contains { $0.id == "llm.summarize" })
        #expect(!config.widgets.contains { $0.id == "llm.plain" })
        #expect(!summary.skippedSections.contains("dictation.user_modes (legacy)"))
        #expect(summary.importedWidgets == 2)
        #expect(summary.unsupportedWidgets == 1)

        let preview = try ScenarioImporter.preview(data: data)
        #expect(preview.importedWidgets == 2)
        #expect(preview.unsupportedWidgets == 1)
        #expect(!preview.skippedSections.contains("dictation.user_modes (legacy)"))
    }

    @Test("imports vocab books and global mounts into the store")
    func importsVocab() throws {
        let store = freshStore()
        _ = try ScenarioImporter.apply(data: sampleScenario, to: AppConfig(), vocabStore: store)
        #expect(store.book(id: "tech")?.terms == ["Kubernetes"])
        #expect(store.mountedIDs(forKey: VocabStore.globalMountKey).contains("tech"))
        let out = VocabApplier.applyRules("my sequel", books: store.effectiveBooks(modeID: nil))
        #expect(out == "MySQL")
    }

    @Test("vocab section replaces desktop snapshot and prunes stale phone mounts")
    func vocabSnapshotReplacesExistingPhoneState() throws {
        let store = freshStore()
        let notebookID = UUID()
        store.upsert(VocabBook(id: "old", name: "Phone only"))
        store.upsert(VocabBook(id: "keep", name: "Old copy"))
        store.setMounted(["old"], forKey: VocabStore.globalMountKey)
        store.setMounted(["old", "keep", "missing"], forKey: VocabStore.modeMountKey("polish"))
        store.setMounted(["old"], forKey: VocabStore.notebookMountKey(notebookID))
        let data = """
        {"vocab":{
          "vocab_books":[
            {"id":"keep","name":"Desktop copy","terms":["updated"]},
            {"id":"fresh","name":"Fresh"}
          ],
          "global_vocab_books":["fresh","future-book"]
        }}
        """.data(using: .utf8)!

        let (_, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: store)

        #expect(store.books.map(\.id) == ["keep", "fresh"])
        #expect(store.book(id: "old") == nil)
        #expect(store.book(id: "keep")?.name == "Desktop copy")
        #expect(store.mountedIDs(forKey: VocabStore.globalMountKey) == ["fresh", "future-book"])
        #expect(store.mountedIDs(forKey: VocabStore.modeMountKey("polish")) == ["keep"])
        #expect(store.mountedIDs(forKey: VocabStore.notebookMountKey(notebookID)).isEmpty)
        #expect(summary.vocabApplied)
        #expect(summary.vocabBooksImported == 2)
    }

    @Test("skips speech and hotkeys sections")
    func skipsIOSIrrelevantSections() throws {
        let (_, summary) = try ScenarioImporter.apply(
            data: sampleScenario, to: AppConfig(), vocabStore: freshStore())
        #expect(summary.skippedSections == ["speech", "hotkeys"])
        #expect(summary.name == "Home Lab")
    }

    @Test("an object with no scenario section is rejected")
    func noSectionIsRejected() throws {
        let data = #"{"id":"x","name":"Empty"}"#.data(using: .utf8)!
        #expect(throws: ScenarioImporter.ImportError.self) {
            _ = try ScenarioImporter.preview(data: data)
        }
        #expect(throws: ScenarioImporter.ImportError.self) {
            _ = try ScenarioImporter.apply(
                data: data, to: AppConfig(), vocabStore: freshStore())
        }
    }

    @Test("desktop legacy flat profiles and assignments migrate into models")
    func legacyFlatModelsMigrate() throws {
        let data = """
        {"name":"Legacy flat","profiles":[
          {"id":"flat-stt","name":"Flat STT","provider":"openai",
           "model":"whisper-1","capabilities":["stt"]}
        ],"assignments":{"stt_profile":"flat-stt","llm_profile":""}}
        """.data(using: .utf8)!

        let preview = try ScenarioImporter.preview(data: data)
        #expect(preview.importedProfiles == 1)
        #expect(preview.sttProfileSet)

        let (config, summary) = try ScenarioImporter.apply(
            data: data,
            to: AppConfig(),
            vocabStore: freshStore(),
            keyReader: { _ in nil },
            keyWriter: { _, _ in },
            keyDeleter: { _ in }
        )
        #expect(config.modelProfiles.first { $0.id == "flat-stt" }?.modelID == "whisper-1")
        #expect(config.sttProfile == "flat-stt")
        #expect(summary.importedProfiles == 1)
    }

    @Test("an explicitly present empty section remains a valid no-op")
    func emptyModelsSectionIsValid() throws {
        let data = #"{"models":{}}"#.data(using: .utf8)!
        let base = AppConfig()
        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: base, vocabStore: freshStore())
        #expect(config == base)
        #expect(summary.importedProfiles == 0)
    }

    @Test("malformed JSON throws")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            _ = try ScenarioImporter.apply(data: Data("not json".utf8),
                                           to: AppConfig(), vocabStore: freshStore())
        }
    }

    @Test("imports latest desktop workflow overlays without discarding unsupported definitions")
    func importsWorkflowOverlays() throws {
        let (config, summary) = try ScenarioImporter.apply(
            data: workflowScenario,
            to: AppConfig(),
            vocabStore: freshStore()
        )

        #expect(summary.importedWidgets == 2)
        #expect(summary.importedWorkflows == 2)
        #expect(summary.unsupportedWidgets == 2) // panel + malformed entry
        #expect(summary.unsupportedWorkflows == 2) // panel recipe + malformed entry
        #expect(summary.adaptedWorkflows == 1) // desktop out.insert surface adaptation
        #expect(config.widgets.contains { $0.id == "out.desktop-panel" })
        #expect(config.workflows.contains { $0.id == "wf.desktop-panel" })
        #expect(config.widgets.first { $0.id == "stt.mobile" }?
            .props["future"]?["nested"] == .array([.integer(1), .bool(true), .string("x")]))
        #expect(config.widgets.first { $0.id == "stt.mobile" }?
            .props["language"]?.stringValue == "English")
        #expect(STTLanguageCode.normalized(config.widgets.first { $0.id == "stt.mobile" }?
            .props["language"]?.stringValue) == "en")
        #expect(config.activeVoiceWorkflowID == "wf.voice.polish")
        #expect(config.workflowSchemaVersion == WorkflowMigration.currentSchemaVersion)
    }

    @Test("latest desktop wf.dictation overlay is the active recipe instead of the legacy mode mapping")
    func importedDictationWorkflowIsAuthoritative() throws {
        let (config, _) = try ScenarioImporter.apply(
            data: overlaidDictationScenario,
            to: AppConfig(),
            vocabStore: freshStore()
        )

        #expect(config.workflowSchemaVersion == WorkflowMigration.currentSchemaVersion)
        #expect(config.activeVoiceWorkflowID == "wf.dictation")
        #expect(config.activeVoiceWorkflow?.processors == ["stt.default", "llm.polish"])
    }

    @Test("invalid imported dictation falls back to the prior runnable recipe")
    func invalidImportedDictationUsesPriorRunnableRecipe() throws {
        var base = AppConfig()
        WorkflowMigration.migrate(&base)
        base.activeVoiceWorkflowID = "wf.voice.formal"
        let data = """
        {"dictation":{"dictation_mode":"raw","user_workflows":[
          {"id":"wf.dictation","name":"Broken","source":"src.mic-hold",
           "processors":["stt.default"],"outputs":[]}
        ]}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: base, vocabStore: freshStore())

        #expect(config.activeVoiceWorkflowID == "wf.voice.formal")
        #expect(summary.activeWorkflowAdjusted)
        #expect(!summary.noRunnableWorkflow)
    }

    @Test("import never activates a recipe with a missing explicit model profile")
    func missingExplicitProfileFallsBack() throws {
        let data = """
        {"dictation":{"active_voice_workflow":"wf.explicit-missing","user_widgets":[
          {"id":"stt.explicit-missing","role":"processor","type_tag":"stt","name":"Missing STT",
           "props":{"model_profile":"not-imported"}}
        ],"user_workflows":[
          {"id":"wf.explicit-missing","name":"Missing","source":"src.mic-hold",
           "processors":["stt.explicit-missing"],"outputs":["out.insert"]}
        ]}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: freshStore())

        #expect(config.activeVoiceWorkflowID == "wf.dictation")
        #expect(summary.activeWorkflowAdjusted)
        #expect(summary.selectedWorkflowID == "wf.dictation")
    }

    @Test("desktop Apple Speech sentinel remains an executable explicit STT choice")
    func appleSpeechSentinelImportsAsRunnable() throws {
        let data = """
        {"dictation":{"active_voice_workflow":"wf.apple","user_widgets":[
          {"id":"stt.apple","role":"processor","type_tag":"stt","name":"Apple Speech",
           "props":{"model_profile":"apple-speech","language":"auto"}}
        ],"user_workflows":[
          {"id":"wf.apple","name":"On-device","source":"src.mic-hold",
           "processors":["stt.apple"],"outputs":["out.insert"]}
        ]}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: freshStore())

        #expect(config.activeVoiceWorkflowID == "wf.apple")
        #expect(!summary.activeWorkflowAdjusted)
    }

    @Test("unknown custom mode never leaves a dangling workflow id")
    func unknownCustomModeFallsBackToCatalogRecipe() throws {
        var base = AppConfig()
        base.workflowSchemaVersion = WorkflowMigration.currentSchemaVersion
        base.activeVoiceWorkflowID = ""
        let data = """
        {"dictation":{"dictation_mode":"desktop-custom","user_workflows":[
          {"id":"wf.dictation","name":"Broken","source":"src.mic-hold",
           "processors":["stt.default"],"outputs":[]}
        ]}}
        """.data(using: .utf8)!

        let (config, _) = try ScenarioImporter.apply(
            data: data, to: base, vocabStore: freshStore())

        #expect(config.activeVoiceWorkflowID == "wf.voice.polish")
        #expect(config.activeVoiceWorkflowID != "wf.custom-desktop-custom")
    }

    @Test("explicit active voice workflow preserves iOS round-trip identity")
    func explicitActiveWorkflowPreservesIdentity() throws {
        let data = """
        {"dictation":{"dictation_mode":"raw","active_voice_workflow":"wf.voice.formal",
          "user_workflows":[
            {"id":"wf.dictation","name":"Projected","source":"src.mic-hold",
             "processors":["stt.default"],"outputs":["out.insert"]}
          ]}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: freshStore())

        #expect(config.activeVoiceWorkflowID == "wf.voice.formal")
        #expect(!summary.activeWorkflowAdjusted)
    }

    @Test("selection is cleared when no microphone workflow validates")
    func noRunnableWorkflowClearsSelection() throws {
        let data = """
        {"dictation":{"dictation_mode":"raw","user_widgets":[
          {"id":"src.mic-hold","role":"output","type_tag":"clipboard","name":"Broken hold source"},
          {"id":"src.mic-toggle","role":"output","type_tag":"clipboard","name":"Broken toggle source"}
        ]}}
        """.data(using: .utf8)!

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: freshStore())

        #expect(config.activeVoiceWorkflowID.isEmpty)
        #expect(summary.noRunnableWorkflow)
    }

    @Test("workflow support uses engine property validation before counting adaptation")
    func supportAssessmentUsesEngineValidation() throws {
        let data = """
        {"dictation":{"user_widgets":[
          {"id":"stt.bad","role":"processor","type_tag":"stt","name":"Bad STT",
           "props":{"temperature":9}}
        ],"user_workflows":[
          {"id":"wf.bad","name":"Bad","source":"src.mic-hold",
           "processors":["stt.bad"],"outputs":["out.insert"]}
        ]}}
        """.data(using: .utf8)!

        let summary = try ScenarioImporter.preview(data: data)

        #expect(summary.unsupportedWorkflows == 1)
        #expect(summary.adaptedWorkflows == 0)
    }

    @Test("preview reports workflow compatibility without mutating")
    func previewsWorkflowCompatibility() throws {
        let summary = try ScenarioImporter.preview(data: workflowScenario)
        #expect(summary.importedWidgets == 2)
        #expect(summary.importedWorkflows == 2)
        #expect(summary.unsupportedWidgets == 2)
        #expect(summary.unsupportedWorkflows == 2)
        #expect(summary.adaptedWorkflows == 1)
    }

    @Test("current desktop summarize listen and explain processors import as supported")
    func currentDesktopBuiltinReferencesAreSupported() throws {
        let data = """
        {"dictation":{"user_workflows":[{
          "id":"wf.desktop-current-builtins","name":"Current desktop processors",
          "source":"src.mic-hold",
          "processors":["stt.default","llm.summarize","llm.listen","llm.explain"],
          "outputs":["out.insert"]
        }]}}
        """.data(using: .utf8)!

        let preview = try ScenarioImporter.preview(data: data)
        #expect(preview.importedWorkflows == 1)
        #expect(preview.unsupportedWorkflows == 0)
        #expect(preview.adaptedWorkflows == 1)

        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: freshStore())
        let catalog = config.workflowCatalog
        #expect(catalog.widget(id: "llm.summarize") != nil)
        #expect(catalog.widget(id: "llm.listen") != nil)
        #expect(catalog.widget(id: "llm.explain") != nil)
        #expect(summary.unsupportedWorkflows == 0)
    }

    @Test("config bundle exports latest desktop user_workflows and user_widgets shape")
    func exportsLatestWorkflowScenarioShape() throws {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "audio-chat",
            name: "Audio Chat",
            provider: "openrouter",
            modelID: "openai/gpt-audio-mini",
            baseURL: " https://openrouter.ai/api/v1/chat/completions/ ",
            capabilities: ["stt"],
            sttAPI: "chat"
        )]
        WorkflowMigration.migrate(&config)
        let data = ConfigBundleExporter.bundleJSON(
            config: config,
            vocabStore: freshStore(),
            name: "Phone",
            includeKeys: false
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dictation = try #require(root["dictation"] as? [String: Any])
        let models = try #require(root["models"] as? [String: Any])
        let profiles = try #require(models["profiles"] as? [[String: Any]])
        #expect(profiles.first { $0["id"] as? String == "audio-chat" }?["stt_api"] as? String == "chat")
        #expect(profiles.first { $0["id"] as? String == "audio-chat" }?["base_url"] as? String
            == "https://openrouter.ai/api")
        #expect(dictation["user_modes"] is NSNull)
        #expect(dictation["active_voice_workflow"] as? String == config.activeVoiceWorkflowID)
        let workflows = try #require(dictation["user_workflows"] as? [[String: Any]])
        let widgets = try #require(dictation["user_widgets"] as? [[String: Any]])
        #expect(workflows.count == config.workflows.count)
        #expect(widgets.count == config.widgets.filter { $0.typeTag != "return_to_caller" }.count)
        #expect(workflows.first?["source"] as? String == "src.mic-toggle")
        #expect(widgets.contains { $0["type_tag"] as? String == "llm" })
        #expect(!widgets.contains { $0["type_tag"] as? String == "return_to_caller" })
        #expect(workflows.allSatisfy { workflow in
            let outputs = workflow["outputs"] as? [String] ?? []
            return !outputs.contains("out.return")
                && outputs.allSatisfy { $0 == "out.insert" || $0 == "out.clipboard" }
        })
        #expect(workflows.filter {
            ($0["id"] as? String)?.hasPrefix("wf.voice.") == true
        }.allSatisfy { ($0["builtin"] as? Bool) == false })

        let preview = try ScenarioImporter.preview(data: data)
        #expect(preview.importedWorkflows == config.workflows.count)
        #expect(preview.importedWidgets == config.widgets.filter { $0.typeTag != "return_to_caller" }.count)
    }

    @Test("scenario projects the selected mobile recipe onto desktop wf.dictation")
    func exportsSelectedRecipeAsDesktopDictation() throws {
        var config = WorkflowMigration.migrated(AppConfig())
        config.activeVoiceWorkflowID = "wf.voice.polish"
        let data = ConfigBundleExporter.bundleJSON(
            config: config,
            vocabStore: freshStore(),
            name: "Polish on phone",
            includeKeys: false
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dictation = try #require(root["dictation"] as? [String: Any])
        let workflows = try #require(dictation["user_workflows"] as? [[String: Any]])
        let desktopDefault = try #require(workflows.first { $0["id"] as? String == "wf.dictation" })

        #expect(desktopDefault["processors"] as? [String] == ["stt.default", "llm.polish"])
        #expect(desktopDefault["outputs"] as? [String] == ["out.insert"])
        #expect(desktopDefault["builtin"] as? Bool == true)
        let triggers = try #require(desktopDefault["triggers"] as? [[String: Any]])
        #expect(triggers.count == 1)
        #expect(triggers.first?["kind"] as? String == "pill_slot")
        #expect(triggers.first?["order"] as? Int == 0)
        #expect(dictation["dictation_mode"] as? String == "polish")
    }

    @Test("desktop dictation projection never duplicates a custom recipe trigger")
    func exportProjectionKeepsCanonicalTriggers() throws {
        var config = WorkflowMigration.migrated(AppConfig())
        let custom = WorkflowDefinition(
            id: "wf.custom-triggered",
            name: "Triggered",
            hotkey: "option+x",
            triggers: [.hotkey(combo: "option+x", capture: "toggle")],
            source: "src.mic-toggle",
            processors: ["stt.default"],
            outputs: ["out.insert"]
        )
        config.workflows.append(custom)
        config.activeVoiceWorkflowID = custom.id

        let data = ConfigBundleExporter.bundleJSON(
            config: config,
            vocabStore: freshStore(),
            name: "Triggered",
            includeKeys: false
        )
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let dictation = try #require(root["dictation"] as? [String: Any])
        let workflows = try #require(dictation["user_workflows"] as? [[String: Any]])
        let projected = try #require(workflows.first { $0["id"] as? String == "wf.dictation" })
        let original = try #require(workflows.first { $0["id"] as? String == custom.id })

        #expect(projected["processors"] as? [String] == ["stt.default"])
        #expect(projected["hotkey"] as? String == "")
        let projectedTriggers = try #require(projected["triggers"] as? [[String: Any]])
        #expect(projectedTriggers.count == 1)
        #expect(projectedTriggers.first?["kind"] as? String == "pill_slot")
        #expect(projectedTriggers.first?["order"] as? Int == 0)
        #expect(original["hotkey"] as? String == "option+x")
        #expect((original["triggers"] as? [[String: Any]])?.count == 1)
    }
}
