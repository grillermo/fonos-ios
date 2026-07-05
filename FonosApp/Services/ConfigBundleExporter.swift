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
            if let base = p.baseURL, !base.isEmpty { d["base_url"] = base }
            if includeKeys, let key = keyLookup(p.id), !key.isEmpty { d["api_key"] = key }
            return d
        }
        root["models"] = [
            "profiles": profiles,
            "assignments": ["stt_profile": config.sttProfile, "llm_profile": config.llmProfile]
        ]

        root["dictation"] = [
            "dictation_mode": config.activeModeID,
            "translate_target": config.translateTargetLanguage
        ]

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
