import Foundation

/// One credential replacement in the model Keychain. A `nil` value removes
/// the credential instead of leaving an older secret attached to the profile.
struct ModelCredentialUpdate: Equatable, Sendable {
    let profileID: String
    let value: String?
}

/// Applies one or more model credential replacements as a best-effort
/// transaction. Keychain has no multi-item transaction API, so every original
/// value is captured before the first write and restored if a later operation
/// fails. A rollback failure is surfaced explicitly instead of being hidden.
enum ModelCredentialTransaction {
    typealias KeyReader = @Sendable (_ profileID: String) throws -> String?
    typealias KeyWriter = @Sendable (_ profileID: String, _ apiKey: String) throws -> Void
    typealias KeyDeleter = @Sendable (_ profileID: String) throws -> Void

    static let defaultReader: KeyReader = { id in
        try KeychainStore(service: "com.fonos.models").get(id)
    }
    static let defaultWriter: KeyWriter = { id, key in
        try KeychainStore(service: "com.fonos.models").set(key, forKey: id)
    }
    static let defaultDeleter: KeyDeleter = { id in
        try KeychainStore(service: "com.fonos.models").delete(id)
    }

    struct Failure: LocalizedError, Sendable {
        let profileID: String
        let operation: String
        let reason: String
        let rollbackReason: String?

        var errorDescription: String? {
            var message = "Could not \(operation) the API key for profile “\(profileID)”: \(reason)"
            if let rollbackReason {
                message += " The previous Keychain state could not be fully restored: \(rollbackReason)"
            } else if operation != "read" {
                message += " No profile or vocabulary changes were applied."
            }
            return message
        }
    }

    private enum Snapshot {
        case missing
        case value(String)
    }

    static func apply(
        _ updates: [ModelCredentialUpdate],
        reader: KeyReader = defaultReader,
        writer: KeyWriter = defaultWriter,
        deleter: KeyDeleter = defaultDeleter
    ) throws {
        let updates = deduplicated(updates)
        guard !updates.isEmpty else { return }

        var snapshots: [String: Snapshot] = [:]
        for update in updates {
            do {
                snapshots[update.profileID] = try reader(update.profileID)
                    .map(Snapshot.value) ?? .missing
            } catch {
                throw Failure(
                    profileID: update.profileID,
                    operation: "read",
                    reason: error.localizedDescription,
                    rollbackReason: nil
                )
            }
        }

        var touchedProfileIDs: [String] = []
        for update in updates {
            guard let snapshot = snapshots[update.profileID],
                  requiresMutation(update, from: snapshot) else { continue }
            do {
                if let value = update.value {
                    try writer(update.profileID, value)
                } else {
                    try deleter(update.profileID)
                }
                touchedProfileIDs.append(update.profileID)
            } catch {
                let rollbackReason = rollback(
                    profileIDs: touchedProfileIDs.reversed(),
                    snapshots: snapshots,
                    writer: writer,
                    deleter: deleter
                )
                throw Failure(
                    profileID: update.profileID,
                    operation: update.value == nil ? "delete" : "save",
                    reason: error.localizedDescription,
                    rollbackReason: rollbackReason
                )
            }
        }
    }

    private static func deduplicated(_ updates: [ModelCredentialUpdate]) -> [ModelCredentialUpdate] {
        var result: [ModelCredentialUpdate] = []
        var indexByProfileID: [String: Int] = [:]
        for update in updates {
            if let index = indexByProfileID[update.profileID] {
                result[index] = update
            } else {
                indexByProfileID[update.profileID] = result.count
                result.append(update)
            }
        }
        return result
    }

    private static func requiresMutation(
        _ update: ModelCredentialUpdate,
        from snapshot: Snapshot
    ) -> Bool {
        switch (snapshot, update.value) {
        case (.missing, nil): false
        case (.value(let current), .some(let replacement)): current != replacement
        default: true
        }
    }

    private static func rollback(
        profileIDs: ReversedCollection<[String]>,
        snapshots: [String: Snapshot],
        writer: KeyWriter,
        deleter: KeyDeleter
    ) -> String? {
        var failures: [String] = []
        for profileID in profileIDs {
            guard let snapshot = snapshots[profileID] else { continue }
            do {
                switch snapshot {
                case .missing:
                    try deleter(profileID)
                case .value(let value):
                    try writer(profileID, value)
                }
            } catch {
                failures.append("\(profileID): \(error.localizedDescription)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "; ")
    }
}

/// Security boundary for deciding whether a key-stripped profile may keep a
/// locally stored credential. Unlike network consent (provider + origin), API
/// keys are scoped to the complete service base because custom gateway paths
/// commonly identify different tenants.
private struct ModelCredentialScopeIdentity: Equatable {
    let provider: String
    let serviceBaseURL: String

    init?(profile: ModelProfile) {
        let baseURL = profile.effectiveBaseURL
        guard let endpoint = RemoteAIEndpointIdentity(
            provider: profile.provider,
            baseURL: baseURL
        ), let components = URLComponents(string: baseURL) else { return nil }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let concreteEndpointSuffixes = [
            "/v1/audio/transcriptions",
            "/v1/chat/completions",
            "/audio/transcriptions",
            "/chat/completions"
        ]
        let lowercasePath = path.lowercased()
        if let suffix = concreteEndpointSuffixes.first(where: {
            lowercasePath.hasSuffix($0)
        }) {
            path.removeLast(suffix.count)
            while path.hasSuffix("/") { path.removeLast() }
        }

        var normalizedURL = endpoint.origin + path
        if let query = components.percentEncodedQuery, !query.isEmpty {
            normalizedURL += "?\(query)"
        }
        provider = endpoint.provider
        serviceBaseURL = normalizedURL
    }
}

/// What a scenario/config import changed (or would change, for a preview).
struct ScenarioImportSummary: Equatable {
    var name: String = ""
    var importedProfiles: Int = 0
    var sttProfileSet = false
    var llmProfileSet = false
    var dictationApplied = false
    var vocabBooksImported: Int = 0
    /// A present vocab section replaces the recipient's complete book list and
    /// global mounts, including when that snapshot is empty.
    var vocabApplied = false
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

struct DictationImport {
    let activeWorkflowID: String?
    let legacyMode: String?
    let translateTarget: String?
    let widgets: [WorkflowWidget]
    let invalidWidgetCount: Int
    let workflows: [WorkflowDefinition]
    let invalidWorkflowCount: Int
    let requiresMigration: Bool

    var hasImportedDictation: Bool {
        workflows.contains { $0.id == "wf.dictation" }
    }

    var mappedLegacyWorkflowID: String? {
        legacyMode.map(WorkflowMigration.workflowID(forLegacyModeID:))
    }
}

struct LegacyModeWidgetImport {
    let widgets: [WorkflowWidget]
    let invalidCount: Int
}

enum LegacyModeWidgetDecode {
    case widget(WorkflowWidget)
    case noLLMContent
    case invalid
}

struct VocabSnapshot {
    let books: [VocabBook]
    let globalMountIDs: [String]
}

struct WorkflowSupportAssessment {
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
        case invalidSection(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .notAScenario:
                "This file is not a Fonos scenario export."
            case .invalidSection(let name, let reason):
                "The \(name) section is invalid: \(reason)"
            }
        }
    }

    /// Injectable credential operations for tests. All operations throw so an
    /// import cannot claim success after a Keychain failure.
    typealias KeyReader = ModelCredentialTransaction.KeyReader
    typealias KeyWriter = ModelCredentialTransaction.KeyWriter
    typealias KeyDeleter = ModelCredentialTransaction.KeyDeleter
    static let defaultKeyReader = ModelCredentialTransaction.defaultReader
    static let defaultKeyWriter = ModelCredentialTransaction.defaultWriter
    static let defaultKeyDeleter = ModelCredentialTransaction.defaultDeleter

    /// Dry-run: what an import of `data` would change, without mutating anything.
    /// Used by the import preview sheet.
    static func preview(data: Data) throws -> ScenarioImportSummary {
        try summarize(normalizedRoot(data: data))
    }

    /// Parses `data` and applies the iOS-relevant sections. Returns the
    /// updated config plus a summary; vocab changes go into `vocabStore`, and
    /// any embedded API keys go through `keyWriter` (Keychain by default).
    static func apply(data: Data,
                      to config: AppConfig,
                      vocabStore: VocabStore,
                      keyReader: KeyReader = defaultKeyReader,
                      keyWriter: KeyWriter = defaultKeyWriter,
                      keyDeleter: KeyDeleter = defaultKeyDeleter) throws -> (AppConfig, ScenarioImportSummary) {
        // Parse, normalize legacy flat model bundles, and validate every
        // destructive section before any Keychain or VocabStore mutation.
        let root = try normalizedRoot(data: data)

        let priorActiveWorkflowID = config.activeVoiceWorkflowID
        var config = config
        var summary = ScenarioImportSummary(name: root["name"] as? String ?? "")
        var credentialUpdates: [ModelCredentialUpdate] = []

        if let models = root["models"] as? [String: Any] {
            applyModels(
                models,
                to: &config,
                summary: &summary,
                credentialUpdates: &credentialUpdates
            )
        }
        if let dictation = root["dictation"] as? [String: Any] {
            applyDictation(
                dictation,
                priorActiveWorkflowID: priorActiveWorkflowID,
                to: &config,
                summary: &summary
            )
        }
        appendSkippedRootSections(root, to: &summary)

        // Perform all fallible external mutations only after the complete
        // config has been parsed and validated. VocabStore is updated last and
        // has no throwing operations, so a Keychain error leaves config and
        // vocabulary untouched.
        try ModelCredentialTransaction.apply(
            credentialUpdates,
            reader: keyReader,
            writer: keyWriter,
            deleter: keyDeleter
        )
        if let vocab = root["vocab"] as? [String: Any] {
            try applyVocab(vocab, to: vocabStore, summary: &summary)
        }
        return (config, summary)
    }

    static let scenarioSectionNames = [
        "models", "dictation", "speech", "vocab", "hotkeys"
    ]

    /// Mirrors desktop `parse_saved_scenario`: a scenario must carry at least
    /// one non-null section. The old flat models-only bundle is normalized into
    /// a models section before validation.
    static func normalizedRoot(data: Data) throws -> [String: Any] {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notAScenario
        }

        let hasSection = scenarioSectionNames.contains { name in
            guard let value = root[name] else { return false }
            return !(value is NSNull)
        }
        if !hasSection {
            guard let profiles = root["profiles"] as? [Any],
                  let assignments = root["assignments"] as? [String: Any] else {
                throw ImportError.notAScenario
            }
            root["models"] = [
                "profiles": profiles,
                "assignments": assignments
            ]
            root.removeValue(forKey: "profiles")
            root.removeValue(forKey: "assignments")
        }

        for name in scenarioSectionNames {
            guard let value = root[name], !(value is NSNull) else { continue }
            guard value is [String: Any] else {
                throw ImportError.invalidSection(name: name, reason: "expected an object")
            }
        }
        if let models = root["models"] as? [String: Any] {
            try validateModelsSection(models)
        }
        if let vocab = root["vocab"] as? [String: Any] {
            _ = try decodeVocabSnapshot(vocab)
        }
        return root
    }

    static func validateModelsSection(_ models: [String: Any]) throws {
        if let profiles = models["profiles"], !(profiles is [Any]) {
            throw ImportError.invalidSection(
                name: "models",
                reason: "profiles must be an array"
            )
        }
        guard let rawAssignments = models["assignments"] else { return }
        guard let assignments = rawAssignments as? [String: Any] else {
            throw ImportError.invalidSection(
                name: "models",
                reason: "assignments must be an object"
            )
        }
        let stringAssignments = [
            "stt_profile", "llm_profile", "tts_profile", "sts_voice_profile",
            "listen_voice_profile", "sts_voice", "listen_voice"
        ]
        for key in stringAssignments where assignments[key] != nil {
            guard assignments[key] is String else {
                throw ImportError.invalidSection(
                    name: "models",
                    reason: "assignments.\(key) must be a string"
                )
            }
        }
    }

    static func applyModels(
        _ models: [String: Any],
        to config: inout AppConfig,
        summary: inout ScenarioImportSummary,
        credentialUpdates: inout [ModelCredentialUpdate]
    ) {
        let existingProfiles = Dictionary(
            config.modelProfiles.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        var finalEntries: [String: (profile: ModelProfile, apiKey: String?)] = [:]
        var profileOrder: [String] = []

        for entry in models["profiles"] as? [[String: Any]] ?? [] {
            guard let profile = mapProfile(entry) else { continue }
            upsert(profile, into: &config.modelProfiles)
            summary.importedProfiles += 1
            let apiKey = (entry["api_key"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            if apiKey == nil {
                summary.profilesNeedingKeys += 1
            }
            if finalEntries[profile.id] == nil { profileOrder.append(profile.id) }
            finalEntries[profile.id] = (profile, apiKey)
        }

        for profileID in profileOrder {
            guard let incoming = finalEntries[profileID] else { continue }
            if let apiKey = incoming.apiKey {
                credentialUpdates.append(ModelCredentialUpdate(profileID: profileID, value: apiKey))
            } else if existingProfiles[profileID].map({
                !hasSameCredentialScope($0, incoming.profile)
            }) ?? true {
                // A key-stripped scenario may preserve a locally entered key
                // only when both provider and network origin are unchanged.
                // New profiles and changed destinations fail closed by
                // removing any orphaned/stale credential with the same id.
                credentialUpdates.append(ModelCredentialUpdate(profileID: profileID, value: nil))
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

    static func hasSameCredentialScope(_ lhs: ModelProfile, _ rhs: ModelProfile) -> Bool {
        guard let lhs = ModelCredentialScopeIdentity(profile: lhs),
              let rhs = ModelCredentialScopeIdentity(profile: rhs) else { return false }
        return lhs == rhs
    }

}
