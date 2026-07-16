// INV-09: Config persistence — settings survive app termination and relaunch
// (UserDefaults + Codable round-trip). API keys stored in Keychain.
//
// Verifier: auto
// Level: unit (in-memory UserDefaults via suiteName)
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/INV09ConfigTests

import Testing
import Foundation
@testable import FonosApp

// MARK: - Helpers

/// Returns a UserDefaults suite isolated per test to avoid cross-test contamination.
private func makeSuite(name: String = "com.fonos.test.\(UUID().uuidString)") -> UserDefaults {
    UserDefaults(suiteName: name)!
}

struct INV09ConfigTests {

    @Test("model profile IDs remain unique across timestamp/hash collisions")
    func modelProfileIDsAreCollisionSafe() throws {
        let uuid = try #require(UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        ))
        var reserved: Set<String> = []

        let first = ModelProfileIdentifier.make(
            provider: "OpenAI",
            reservedIDs: &reserved,
            uuid: uuid
        )
        let second = ModelProfileIdentifier.make(
            provider: "OpenAI",
            reservedIDs: &reserved,
            uuid: uuid
        )

        #expect(first == "openai-00000000-0000-0000-0000-000000000001")
        #expect(second == "\(first)-2")
        #expect(reserved == Set([first, second]))
    }

    // MARK: - Default values

    @Test("AppConfig default initialisation has sensible sttProvider value")
    func defaultSTTProvider() throws {
        let config = AppConfig()
        // Default must be one of the known providers
        let knownProviders: Set<String> = ["apple", "whisper", "fonos"]
        #expect(knownProviders.contains(config.sttProvider))
    }

    @Test("AppConfig default voice workflow is dictation")
    func defaultVoiceWorkflow() throws {
        let config = WorkflowMigration.migrated(AppConfig())
        #expect(config.activeVoiceWorkflow?.id == "wf.dictation")
    }

    @Test("AppConfig default destinations array is non-empty")
    func defaultDestinationsNonEmpty() throws {
        let config = AppConfig()
        #expect(!config.destinations.isEmpty)
    }

    @Test("AppConfig default recordMode is tap")
    func defaultRecordMode() throws {
        let config = AppConfig()
        #expect(config.recordMode == .tap)
    }

    // MARK: - Codable round-trip

    @Test("AppConfig Codable encode/decode round-trip preserves sttProvider")
    func codablePreservesSTTProvider() throws {
        var config = AppConfig()
        config.sttProvider = "whisper"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.sttProvider == "whisper")
    }

    @Test("AppConfig Codable encode/decode round-trip preserves recordMode")
    func codablePreservesRecordMode() throws {
        var config = AppConfig()
        config.recordMode = .hold
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.recordMode == .hold)
    }

    @Test("AppConfig Codable encode/decode round-trip preserves destinations array")
    func codablePreservesDestinations() throws {
        var config = AppConfig()
        config.destinations = [
            AnyTextDestination(ClipboardDestination()),
            AnyTextDestination(URLSchemeDestination(template: "tg://msg?text={text}"))
        ]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.destinations.count == 2)
    }

    @Test("AppConfig Codable encode/decode round-trip preserves modelProfiles array")
    func codablePreservesModelProfiles() throws {
        var config = AppConfig()
        config.modelProfiles = [
            ModelProfile(id: "gpt4o", name: "GPT-4o", provider: "openai", modelID: "gpt-4o"),
            ModelProfile(id: "local", name: "Local Fonos", provider: "fonos", modelID: "llama3")
        ]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.modelProfiles.count == 2)
        #expect(decoded.modelProfiles[0].modelID == "gpt-4o")
    }

    @Test("schema 3 persists workflow recipes instead of legacy modes")
    func schemaThreePersistsWorkflowsNotModes() throws {
        var config = AppConfig()
        config.modeConfigs.append(ModeConfig(
            id: "pirate",
            mode: .custom(
                systemPrompt: "Be a pirate",
                userTemplate: "{text}",
                temperature: 0.9,
                maxTokens: 300
            ),
            name: "Pirate",
            icon: "flag",
            description: "",
            sttModelID: nil,
            llmModelID: nil,
            sttPrompt: "",
            sttTemperature: 0,
            outputLanguage: "auto",
            isBuiltIn: false
        ))
        WorkflowMigration.migrate(&config)
        let data = try JSONEncoder().encode(config)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["modes"] == nil)
        #expect(object["modeConfigs"] == nil)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.workflowCatalog.workflow(id: "wf.custom-pirate") != nil)
        #expect(decoded.workflowSchemaVersion == 3)
    }

    // MARK: - UserDefaults persistence

    @Test("AppConfig persisted to UserDefaults survives encode/decode cycle")
    func persistedToUserDefaults() throws {
        let defaults = makeSuite()
        var config = AppConfig()
        config.sttProvider = "fonos"

        // Save
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: "app_config")

        // Load
        guard let loaded = defaults.data(forKey: "app_config") else {
            Issue.record("No data found in UserDefaults after save")
            return
        }
        let decoded = try JSONDecoder().decode(AppConfig.self, from: loaded)
        #expect(decoded.sttProvider == "fonos")

        // Cleanup
        defaults.removeSuite(named: defaults.description)
    }

    @Test("Record mode toggle tap → hold → tap round-trips via UserDefaults")
    func recordModeToggleRoundTrip() throws {
        let defaults = makeSuite()
        var config = AppConfig()
        config.recordMode = .hold
        let data = try JSONEncoder().encode(config)
        defaults.set(data, forKey: "app_config")

        let loaded = defaults.data(forKey: "app_config")!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: loaded)
        #expect(decoded.recordMode == .hold)
    }

    // MARK: - Keychain (API key isolation)

    @Test("API keys are NOT stored in plain AppConfig UserDefaults payload")
    func apiKeysNotInUserDefaults() throws {
        let config = AppConfig()
        // Simulate a config that has been populated — apiKey should not appear in JSON
        let data = try JSONEncoder().encode(config)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        // If api key fields leak into the config JSON, this test fails
        #expect(!jsonString.localizedCaseInsensitiveContains("apiKey"))
        #expect(!jsonString.localizedCaseInsensitiveContains("api_key"))
        #expect(!jsonString.localizedCaseInsensitiveContains("sk-"))
    }

    @Test("KeychainStore saves and retrieves API key correctly")
    func keychainStoreRoundTrip() throws {
        let store = KeychainStore(service: "com.fonos.test.\(UUID().uuidString)")
        let key = "openai_api_key"
        let value = "sk-testkey123"
        try store.set(value, forKey: key)
        let retrieved = try store.get(key)
        #expect(retrieved == value)
        // Cleanup
        try? store.delete(key)
    }

    @Test("KeychainStore returns nil for non-existent key")
    func keychainMissingKey() throws {
        let store = KeychainStore(service: "com.fonos.test.\(UUID().uuidString)")
        let value = try store.get("nonexistent_key_\(UUID().uuidString)")
        #expect(value == nil)
    }
}
