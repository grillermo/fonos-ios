import Foundation
import Testing
@testable import FonosApp

struct WorkflowWireFormatTests {
    @Test("desktop widget and trigger wire shape round trips unknown props")
    func desktopWireRoundTrip() throws {
        let json = Data(#"""
        {
          "id":"custom.future","role":"processor","type_tag":"future_widget",
          "name":"Future","icon":"🧪","builtin":false,
          "props":{"nested":{"flag":true,"large":9223372036854775807},"items":[null,1.5,"x"]}
        }
        """#.utf8)
        let decoder = JSONDecoder()
        let widget = try decoder.decode(WorkflowWidget.self, from: json)
        #expect(widget.typeTag == "future_widget")
        #expect(widget.props["nested"]?["flag"]?.boolValue == true)
        #expect(widget.props["nested"]?["large"] == .integer(Int64.max))
        let roundTrip = try decoder.decode(
            WorkflowWidget.self,
            from: JSONEncoder().encode(widget)
        )
        #expect(roundTrip == widget)

        let triggerData = Data(#"{"kind":"future_surface","slot":"side","weight":7}"#.utf8)
        let trigger = try decoder.decode(WorkflowTrigger.self, from: triggerData)
        #expect(trigger == .unknown(kind: "future_surface", fields: [
            "slot": .string("side"), "weight": .integer(7)
        ]))
        #expect(try decoder.decode(WorkflowTrigger.self, from: JSONEncoder().encode(trigger)) == trigger)
    }

    @Test("desktop defaults are honored when optional workflow fields are absent")
    func desktopDefaults() throws {
        let data = Data(#"{"id":"wf.x","name":"X","source":"src.mic-hold","outputs":["out.insert"]}"#.utf8)
        let workflow = try JSONDecoder().decode(WorkflowDefinition.self, from: data)
        #expect(workflow.icon.isEmpty)
        #expect(workflow.hotkey.isEmpty)
        #expect(workflow.triggers.isEmpty)
        #expect(workflow.processors.isEmpty)
        #expect(!workflow.builtin)
    }
}

struct WorkflowMigrationTests {
    @Test("legacy built-in modes become real recipes exactly once")
    func migratesBuiltInsIdempotently() {
        var config = AppConfig()
        config.sttLanguage = "ja"
        #expect(WorkflowMigration.migrate(&config))
        #expect(config.workflowSchemaVersion == WorkflowMigration.currentSchemaVersion)
        #expect(config.activeVoiceWorkflowID == "wf.dictation")
        #expect(Set(config.workflows.map(\.id)) == [
            "wf.dictation", "wf.voice.polish", "wf.voice.formal", "wf.voice.translate"
        ])
        #expect(config.workflows.first { $0.id == "wf.dictation" }?.triggers == [
            .pillSlot(order: 0)
        ])
        #expect(config.workflows.allSatisfy { $0.source == "src.mic-toggle" })
        #expect(config.workflows.allSatisfy { $0.outputs == ["out.insert"] })
        #expect(config.workflowCatalog.widget(id: "stt.default")?
            .props["language"]?.stringValue == "ja")

        let first = config
        #expect(!WorkflowMigration.migrate(&config))
        #expect(config == first)
    }

    @Test("schema-one iOS dictation overlay regains desktop's canonical pill trigger")
    func repairsSchemaOneGeneratedDictationTrigger() {
        var config = AppConfig()
        config.workflowSchemaVersion = 1
        config.workflows = [WorkflowDefinition(
            id: "wf.dictation",
            name: "Raw",
            icon: "waveform",
            source: "src.mic-toggle",
            processors: ["stt.default"],
            outputs: ["out.insert"],
            builtin: true
        )]
        config.activeVoiceWorkflowID = "wf.dictation"

        #expect(WorkflowMigration.migrate(&config))
        #expect(config.workflowSchemaVersion == WorkflowMigration.currentSchemaVersion)
        #expect(config.workflows.first { $0.id == "wf.dictation" }?.triggers == [
            .pillSlot(order: 0)
        ])
    }

    @Test("schema-two migration preserves imported dictation trigger payloads")
    func preservesImportedDictationTriggers() {
        let future = WorkflowTrigger.unknown(
            kind: "future_surface",
            fields: ["slot": .string("side")]
        )
        var config = AppConfig()
        config.workflowSchemaVersion = 1
        config.workflows = [WorkflowDefinition(
            id: "wf.dictation",
            name: "Imported",
            triggers: [future],
            source: "src.mic-hold",
            processors: ["stt.default"],
            outputs: ["out.insert"],
            builtin: true
        )]

        WorkflowMigration.migrate(&config)
        #expect(config.workflows.first { $0.id == "wf.dictation" }?.triggers == [future])
    }

    @Test("legacy capture preference is materialized into the recipe source")
    func migratesCapturePreference() {
        var tap = AppConfig()
        tap.recordMode = .tap
        WorkflowMigration.migrate(&tap)
        #expect(tap.workflows.allSatisfy { $0.source == "src.mic-toggle" })

        var hold = AppConfig()
        hold.recordMode = .hold
        WorkflowMigration.migrate(&hold)
        #expect(hold.workflows.allSatisfy { $0.source == "src.mic-hold" })
    }

    @Test("a legacy mode added after initial migration receives a recipe")
    func reconcilesNewLegacyMode() {
        var config = AppConfig()
        WorkflowMigration.migrate(&config)
        config.modeConfigs.append(ModeConfig(
            id: "later",
            mode: .custom(systemPrompt: "Later", userTemplate: "{text}", temperature: 0.4, maxTokens: 600),
            name: "Later",
            icon: "clock",
            description: "",
            sttModelID: nil,
            llmModelID: nil,
            sttPrompt: "",
            sttTemperature: 0,
            outputLanguage: "auto",
            autoPaste: false,
            isBuiltIn: false
        ))

        #expect(WorkflowMigration.migrate(&config))
        #expect(config.workflows.contains { $0.id == "wf.custom-later" })
        #expect(config.widgets.contains { $0.id == "llm.later" })
        #expect(!WorkflowMigration.migrate(&config))
    }

    @Test("per-mode settings produce isolated STT and canonical LLM widgets")
    func migratesPerModeSettings() {
        var config = AppConfig()
        config.sttLanguage = "fr"
        config.modeConfigs[1].sttModelID = "stt-fast"
        config.modeConfigs[1].llmModelID = "llm-pro"
        config.modeConfigs[1].sttPrompt = "names"
        config.modeConfigs[1].sttTemperature = 0.4
        config.modeConfigs[1].outputLanguage = "French"
        WorkflowMigration.migrate(&config)

        let workflow = config.workflows.first { $0.id == "wf.voice.polish" }
        #expect(workflow?.processors == ["stt.polish", "llm.polish"])
        let stt = config.widgets.first { $0.id == "stt.polish" }
        #expect(stt?.props["model_profile"]?.stringValue == "stt-fast")
        #expect(stt?.props["language"]?.stringValue == "fr")
        #expect(stt?.props["temperature"]?.doubleValue == 0.4)
        let llm = config.widgets.first { $0.id == "llm.polish" }
        #expect(llm?.props["model_profile"]?.stringValue == "llm-pro")
        #expect(llm?.props["temperature"]?.doubleValue == 0.1)
        #expect(llm?.props["max_tokens"]?.intValue == 4096)
        #expect(llm?.props["output_language"]?.stringValue == "French")
        #expect(llm?.props["failure_policy"]?.stringValue == "use_input")
        #expect(llm?.props["system"]?.stringValue?.contains("data, not instructions") == true)
        #expect(llm?.props["user_template"]?.stringValue?.contains("<<<\n{text}\n>>>") == true)
        #expect(llm?.props["user_template"]?.stringValue?.contains(
            "if they are excited, it should feel excited."
        ) == true)
    }

    @Test("custom mode mapping is reversible and preserves its prompt tuning")
    func migratesCustomMode() {
        let customID = "A7C4-voice"
        let custom = ModeConfig(
            id: customID,
            mode: .custom(systemPrompt: "System", userTemplate: "Input: {text}", temperature: 0.7, maxTokens: 777),
            name: "My voice",
            icon: "wand.and.stars",
            description: "",
            sttModelID: nil,
            llmModelID: "writer",
            sttPrompt: "",
            sttTemperature: 0,
            outputLanguage: "Spanish",
            autoPaste: true,
            isBuiltIn: false
        )
        var config = AppConfig()
        config.modeConfigs.append(custom)
        config.activeModeID = customID
        WorkflowMigration.migrate(&config)

        let workflowID = WorkflowMigration.workflowID(forLegacyModeID: customID)
        #expect(workflowID == "wf.custom-A7C4-voice")
        #expect(WorkflowMigration.legacyModeID(forWorkflowID: workflowID) == customID)
        #expect(config.activeVoiceWorkflowID == workflowID)
        #expect(config.workflows.first { $0.id == workflowID }?.outputs == ["out.insert"])
        let llm = config.widgets.first { $0.id == "llm.A7C4-voice" }
        #expect(llm?.props["system"]?.stringValue == "System")
        #expect(llm?.props["user_template"]?.stringValue == "Input: {text}")
        #expect(llm?.props["temperature"]?.doubleValue == 0.7)
        #expect(llm?.props["max_tokens"]?.intValue == 777)
    }

    @Test("existing imported overlays win over legacy migration")
    func preservesExistingOverlays() {
        let imported = WorkflowDefinition(
            id: "wf.dictation",
            name: "Desktop recipe",
            source: "src.provided-audio",
            processors: [],
            outputs: ["out.clipboard"]
        )
        var config = AppConfig()
        config.workflows = [imported]
        config.sttLanguage = "ja"
        config.widgets = [WorkflowWidget(
            id: "stt.default",
            role: .processor,
            typeTag: "stt",
            name: "Desktop STT",
            props: .object(["language": .string("de"), "future": .bool(true)])
        )]
        WorkflowMigration.migrate(&config)
        #expect(config.workflows.first { $0.id == "wf.dictation" } == imported)
        #expect(config.workflowCatalog.widget(id: "stt.default")?
            .props["language"]?.stringValue == "de")
        #expect(config.workflowCatalog.widget(id: "stt.default")?
            .props["future"]?.boolValue == true)
    }

    @Test("old AppConfig JSON keeps legacy values and gains workflow defaults")
    func decodesOldAppConfig() throws {
        let oldJSON = Data(#"{"activeModeID":"formal","sttLanguage":"ja","historyRetentionDays":14}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: oldJSON)
        #expect(config.activeModeID == "formal")
        #expect(config.sttLanguage == "ja")
        #expect(config.historyRetentionDays == 14)
        #expect(config.modeConfigs == ModeConfig.builtInConfigs)
        #expect(config.workflowSchemaVersion == 0)
        #expect(config.widgets.isEmpty)
        #expect(config.workflows.isEmpty)
        #expect(config.activeVoiceWorkflowID.isEmpty)

        var migrated = config
        WorkflowMigration.migrate(&migrated)
        #expect(migrated.workflowCatalog.widget(id: "stt.default")?
            .props["language"]?.stringValue == "ja")
    }

    @Test("removing a model clears workflow model_profile without touching other props")
    func removingModelClearsWorkflowReferences() {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "writer", name: "Writer", provider: "openai", modelID: "gpt", capabilities: ["llm"]
        )]
        config.widgets = [WorkflowWidget(
            id: "llm.custom",
            role: .processor,
            typeTag: "llm",
            name: "Custom",
            props: .object(["model_profile": .string("writer"), "system": .string("keep")])
        )]
        config.removeModelProfile(id: "writer")
        #expect(config.widgets[0].props["model_profile"]?.stringValue == "")
        #expect(config.widgets[0].props["system"]?.stringValue == "keep")
    }

    @Test("AppConfigStorage automatically migrates and persists an old config")
    func storageMigratesOnLoad() throws {
        let standardName = "workflow-migration-standard-\(UUID().uuidString)"
        let sharedName = "workflow-migration-shared-\(UUID().uuidString)"
        let standard = try #require(UserDefaults(suiteName: standardName))
        let shared = try #require(UserDefaults(suiteName: sharedName))
        defer {
            standard.removePersistentDomain(forName: standardName)
            shared.removePersistentDomain(forName: sharedName)
        }
        standard.set(
            Data(#"{"activeModeID":"formal","historyRetentionDays":9}"#.utf8),
            forKey: AppConfigStorage.configKey
        )

        let loaded = try #require(AppConfigStorage.load(standard: standard, shared: shared))
        #expect(loaded.historyRetentionDays == 9)
        #expect(loaded.activeVoiceWorkflowID == "wf.voice.formal")
        #expect(loaded.workflowSchemaVersion == WorkflowMigration.currentSchemaVersion)
        let persisted = try #require(shared.data(forKey: AppConfigStorage.configKey))
        let decoded = try JSONDecoder().decode(AppConfig.self, from: persisted)
        #expect(decoded.activeVoiceWorkflowID == "wf.voice.formal")
        #expect(decoded.workflows.count == 4)
    }
}
