import Foundation

/// What a scenario/config import changed (or would change, for a preview).
struct ScenarioImportSummary: Equatable {
    var name: String = ""
    var importedProfiles: Int = 0
    var sttProfileSet = false
    var llmProfileSet = false
    var dictationApplied = false
    var vocabBooksImported: Int = 0
    /// Profiles arriving without an embedded API key — the recipient must enter
    /// one for these if the provider needs it.
    var profilesNeedingKeys: Int = 0
    var skippedSections: [String] = []
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

        var config = config
        var summary = ScenarioImportSummary(name: root["name"] as? String ?? "")

        // ── models: profiles + default assignments ──────────────────────
        if let models = root["models"] as? [String: Any] {
            for entry in models["profiles"] as? [[String: Any]] ?? [] {
                guard let profile = mapProfile(entry) else { continue }
                if let index = config.modelProfiles.firstIndex(where: { $0.id == profile.id }) {
                    config.modelProfiles[index] = profile
                } else {
                    config.modelProfiles.append(profile)
                }
                summary.importedProfiles += 1
                if let key = entry["api_key"] as? String, !key.isEmpty {
                    keyWriter(profile.id, key)
                } else {
                    summary.profilesNeedingKeys += 1
                }
            }
            if let assignments = models["assignments"] as? [String: Any] {
                if let stt = assignments["stt_profile"] as? String, !stt.isEmpty {
                    config.sttProfile = stt
                    summary.sttProfileSet = true
                }
                if let llm = assignments["llm_profile"] as? String, !llm.isEmpty {
                    config.llmProfile = llm
                    summary.llmProfileSet = true
                }
            }
        }

        // ── dictation: active mode + translate target ────────────────────
        if let dictation = root["dictation"] as? [String: Any] {
            if let mode = dictation["dictation_mode"] as? String, !mode.isEmpty {
                config.activeModeID = mode
                summary.dictationApplied = true
            }
            if let target = dictation["translate_target"] as? String, !target.isEmpty {
                config.translateTargetLanguage = target
                summary.dictationApplied = true
            }
        }

        // ── vocab: books + global mounts ─────────────────────────────────
        if let vocab = root["vocab"] as? [String: Any] {
            if let bookObjects = vocab["vocab_books"] as? [[String: Any]] {
                for object in bookObjects {
                    guard let bookData = try? JSONSerialization.data(withJSONObject: object),
                          let book = try? JSONDecoder().decode(VocabBook.self, from: bookData),
                          !book.id.isEmpty else { continue }
                    vocabStore.upsert(book)
                    summary.vocabBooksImported += 1
                }
            }
            for id in vocab["global_vocab_books"] as? [String] ?? [] {
                vocabStore.setMounted(true, bookID: id, forKey: VocabStore.globalMountKey)
            }
        }

        // ── iOS-irrelevant sections ──────────────────────────────────────
        if root["speech"] != nil { summary.skippedSections.append("speech") }
        if root["hotkeys"] != nil { summary.skippedSections.append("hotkeys") }

        return (config, summary)
    }

    /// Counts what an import would change, without mutating (for the preview).
    private static func summarize(_ root: [String: Any]) -> ScenarioImportSummary {
        var s = ScenarioImportSummary(name: root["name"] as? String ?? "")

        if let models = root["models"] as? [String: Any] {
            for entry in models["profiles"] as? [[String: Any]] ?? [] {
                guard (entry["id"] as? String)?.isEmpty == false else { continue }
                s.importedProfiles += 1
                let hasKey = (entry["api_key"] as? String).map { !$0.isEmpty } ?? false
                if !hasKey { s.profilesNeedingKeys += 1 }
            }
            if let a = models["assignments"] as? [String: Any] {
                if let stt = a["stt_profile"] as? String, !stt.isEmpty { s.sttProfileSet = true }
                if let llm = a["llm_profile"] as? String, !llm.isEmpty { s.llmProfileSet = true }
            }
        }
        if let d = root["dictation"] as? [String: Any] {
            let mode = (d["dictation_mode"] as? String).map { !$0.isEmpty } ?? false
            let target = (d["translate_target"] as? String).map { !$0.isEmpty } ?? false
            s.dictationApplied = mode || target
        }
        if let vocab = root["vocab"] as? [String: Any] {
            s.vocabBooksImported = (vocab["vocab_books"] as? [[String: Any]] ?? [])
                .filter { ($0["id"] as? String)?.isEmpty == false }.count
        }
        if root["speech"] != nil { s.skippedSections.append("speech") }
        if root["hotkeys"] != nil { s.skippedSections.append("hotkeys") }
        return s
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
            capabilities: entry["capabilities"] as? [String] ?? ["llm"]
        )
    }
}
