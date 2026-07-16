// Item 3 (shareable config sets + QR): bundle codec, exporter, set store, and
// the ScenarioImporter preview/key round-trip. Pure logic — UI/camera verified
// manually.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/ConfigBundleCodecTests

import Testing
import Foundation
import os
@testable import FonosApp

private func json(_ obj: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: obj)
}

private func obj(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func freshDefaults() -> UserDefaults {
    let name = "configsharing-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private enum CredentialFixtureError: LocalizedError, Sendable {
    case read(String)
    case write(String)
    case delete(String)

    var errorDescription: String? {
        switch self {
        case .read(let id): "read failed for \(id)"
        case .write(let id): "write failed for \(id)"
        case .delete(let id): "delete failed for \(id)"
        }
    }
}

private final class TestKeyVault: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private let failingReads: Set<String>
    private let failingWrites: Set<String>
    private let failingDeletes: Set<String>

    init(
        values: [String: String] = [:],
        failingReads: Set<String> = [],
        failingWrites: Set<String> = [],
        failingDeletes: Set<String> = []
    ) {
        self.values = values
        self.failingReads = failingReads
        self.failingWrites = failingWrites
        self.failingDeletes = failingDeletes
    }

    func read(_ id: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if failingReads.contains(id) { throw CredentialFixtureError.read(id) }
        return values[id]
    }

    func write(_ id: String, _ value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failingWrites.contains(id) { throw CredentialFixtureError.write(id) }
        values[id] = value
    }

    func delete(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failingDeletes.contains(id) { throw CredentialFixtureError.delete(id) }
        values.removeValue(forKey: id)
    }

    subscript(_ id: String) -> String? {
        lock.withLock { values[id] }
    }
}

// MARK: - Codec

struct ConfigBundleCodecTests {

    @Test("URL round-trips back to the same bundle JSON")
    func urlRoundTrip() throws {
        let bundle = json(["version": 1, "name": "Home Lab",
                           "models": ["assignments": ["stt_profile": "s1"]]])
        let url = ConfigBundleCodec.encodeURL(bundleJSON: bundle)
        #expect(url.scheme == "fonos")
        #expect(url.host == "config")
        let decoded = try ConfigBundleCodec.decode(url.absoluteString)
        #expect(obj(decoded)["name"] as? String == "Home Lab")
    }

    @Test("decode accepts a bare base64url payload")
    func decodeBarePayload() throws {
        let bundle = json(["name": "Bare"])
        let payload = ConfigBundleCodec.encodePayload(bundleJSON: bundle)
        #expect(obj(try ConfigBundleCodec.decode(payload))["name"] as? String == "Bare")
    }

    @Test("decode accepts raw bundle JSON")
    func decodeRawJSON() throws {
        let decoded = try ConfigBundleCodec.decode(#"{"name":"Raw"}"#)
        #expect(obj(decoded)["name"] as? String == "Raw")
    }

    @Test("decode rejects arbitrary text")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) { _ = try ConfigBundleCodec.decode("hello world") }
    }

    @Test("decode rejects a non-fonos URL")
    func rejectsWrongScheme() {
        #expect(throws: (any Error).self) {
            _ = try ConfigBundleCodec.decode("https://example.com/config?d=abc")
        }
    }

    @Test("fitsQR is true for a small bundle and false for a large one")
    func fitsQR() {
        #expect(ConfigBundleCodec.fitsQR(bundleJSON: json(["name": "small"])))
        let bigTerms = (0..<4000).map { "term\($0)" }
        let big = json(["name": "big", "vocab": ["vocab_books": [["id": "b", "terms": bigTerms]]]])
        #expect(!ConfigBundleCodec.fitsQR(bundleJSON: big))
    }
}

// MARK: - Exporter

struct ConfigBundleExporterTests {

    private func configWithProfiles() -> AppConfig {
        var c = AppConfig()
        c.modelProfiles = [
            ModelProfile(id: "stt1", name: "ASR", provider: "omlx", modelID: "qwen-asr",
                         baseURL: "http://192.168.1.5:8000", capabilities: ["stt"]),
            ModelProfile(id: "llm1", name: "Chat", provider: "openai", modelID: "gpt-4o",
                         baseURL: "https://api.openai.com", capabilities: ["llm"]),
        ]
        c.sttProfile = "stt1"
        c.llmProfile = "llm1"
        return c
    }

    @Test("bundle contains profiles and assignments")
    func bundleProfiles() {
        let data = ConfigBundleExporter.bundleJSON(
            config: configWithProfiles(), vocabStore: VocabStore(defaults: freshDefaults()),
            name: "Set A", includeKeys: false, keyLookup: { _ in nil })
        let root = obj(data)
        #expect(root["name"] as? String == "Set A")
        let models = root["models"] as? [String: Any]
        let profiles = models?["profiles"] as? [[String: Any]]
        #expect(profiles?.count == 2)
        let assignments = models?["assignments"] as? [String: Any]
        #expect(assignments?["stt_profile"] as? String == "stt1")
    }

    @Test("bundle exports STT service bases instead of concrete transcription routes")
    func bundleCanonicalizesSTTEndpoints() {
        var versioned = ModelProfile(
            id: "versioned", name: "Versioned", provider: "custom", modelID: "whisper",
            capabilities: ["stt"]
        )
        var unversioned = ModelProfile(
            id: "unversioned", name: "Unversioned", provider: "custom", modelID: "whisper",
            capabilities: ["stt"]
        )
        // Simulate profiles decoded from an older AppConfig, whose synthesized
        // decoder can retain the concrete endpoint in the stored property.
        versioned.baseURL = "https://speech.example/gateway/v1/audio/transcriptions/"
        unversioned.baseURL = "https://speech.example/tenant/audio/transcriptions"
        var config = AppConfig()
        config.modelProfiles = [versioned, unversioned]

        let data = ConfigBundleExporter.bundleJSON(
            config: config,
            vocabStore: VocabStore(defaults: freshDefaults()),
            name: "Portable endpoints",
            includeKeys: false,
            keyLookup: { _ in nil }
        )
        let profiles = (obj(data)["models"] as? [String: Any])?["profiles"]
            as? [[String: Any]] ?? []

        #expect(profiles.first { $0["id"] as? String == "versioned" }?["base_url"] as? String
            == "https://speech.example/gateway")
        #expect(profiles.first { $0["id"] as? String == "unversioned" }?["base_url"] as? String
            == "https://speech.example/tenant")
    }

    @Test("translate export uses flow state and only falls back to legacy before schema 3")
    func translateTargetSchemaFallback() {
        func exportedTarget(_ config: AppConfig) -> String? {
            let data = ConfigBundleExporter.bundleJSON(
                config: config,
                vocabStore: VocabStore(defaults: freshDefaults()),
                name: "Translate",
                includeKeys: false,
                keyLookup: { _ in nil }
            )
            return (obj(data)["dictation"] as? [String: Any])?["translate_target"] as? String
        }

        var legacy = AppConfig()
        legacy.workflowSchemaVersion = 2
        legacy.translateTargetLanguage = "French"
        #expect(exportedTarget(legacy) == "French")

        var flowOwned = legacy
        flowOwned.widgets = [WorkflowWidget(
            id: "llm.translate",
            role: .processor,
            typeTag: "llm",
            name: "Custom translate",
            props: .object(["output_language": .string("Spanish")]),
            builtin: false
        )]
        #expect(exportedTarget(flowOwned) == "Spanish")

        var retired = AppConfig()
        retired.workflowSchemaVersion = WorkflowMigration.currentSchemaVersion
        retired.translateTargetLanguage = "German"
        #expect(exportedTarget(retired) == "English")
    }

    @Test("bundle is keyless by default")
    func keylessByDefault() {
        let data = ConfigBundleExporter.bundleJSON(
            config: configWithProfiles(), vocabStore: VocabStore(defaults: freshDefaults()),
            name: "X", includeKeys: false, keyLookup: { _ in "SECRET" })
        let profiles = (obj(data)["models"] as? [String: Any])?["profiles"] as? [[String: Any]] ?? []
        #expect(profiles.allSatisfy { $0["api_key"] == nil })
    }

    @Test("bundle includes keys when requested")
    func includesKeysWhenAsked() {
        let data = ConfigBundleExporter.bundleJSON(
            config: configWithProfiles(), vocabStore: VocabStore(defaults: freshDefaults()),
            name: "X", includeKeys: true, keyLookup: { id in id == "llm1" ? "sk-live" : nil })
        let profiles = (obj(data)["models"] as? [String: Any])?["profiles"] as? [[String: Any]] ?? []
        let llm = profiles.first { $0["id"] as? String == "llm1" }
        #expect(llm?["api_key"] as? String == "sk-live")
        let stt = profiles.first { $0["id"] as? String == "stt1" }
        #expect(stt?["api_key"] == nil)
    }

    @Test("injectingKeys adds keys to a keyless bundle")
    func injectKeys() {
        let keyless = ConfigBundleExporter.bundleJSON(
            config: configWithProfiles(), vocabStore: VocabStore(defaults: freshDefaults()),
            name: "X", includeKeys: false, keyLookup: { _ in nil })
        let withKeys = ConfigBundleExporter.injectingKeys(into: keyless, keyLookup: { _ in "k" })
        let profiles = (obj(withKeys)["models"] as? [String: Any])?["profiles"] as? [[String: Any]] ?? []
        #expect(profiles.allSatisfy { $0["api_key"] as? String == "k" })
    }

    @Test("bundle carries vocab books and global mounts")
    func bundleVocab() {
        let store = VocabStore(defaults: freshDefaults())
        store.upsert(VocabBook(id: "tech", name: "Tech", terms: ["Kubernetes"]))
        store.setMounted(["tech"], forKey: VocabStore.globalMountKey)
        let data = ConfigBundleExporter.bundleJSON(
            config: AppConfig(), vocabStore: store, name: "X", includeKeys: false, keyLookup: { _ in nil })
        let vocab = obj(data)["vocab"] as? [String: Any]
        #expect((vocab?["vocab_books"] as? [[String: Any]])?.count == 1)
        #expect((vocab?["global_vocab_books"] as? [String]) == ["tech"])
    }

    @Test("an empty exported vocab snapshot clears an older target store")
    func emptyVocabRoundTripClearsTarget() throws {
        let source = VocabStore(defaults: freshDefaults())
        let data = ConfigBundleExporter.bundleJSON(
            config: AppConfig(),
            vocabStore: source,
            name: "Empty vocab",
            includeKeys: false,
            keyLookup: { _ in nil }
        )
        let exportedVocab = try #require(obj(data)["vocab"] as? [String: Any])
        #expect((exportedVocab["vocab_books"] as? [Any])?.isEmpty == true)
        #expect((exportedVocab["global_vocab_books"] as? [Any])?.isEmpty == true)

        let target = VocabStore(defaults: freshDefaults())
        target.upsert(VocabBook(id: "old", name: "Old"))
        target.setMounted(["old"], forKey: VocabStore.globalMountKey)

        let (_, summary) = try ScenarioImporter.apply(
            data: data,
            to: AppConfig(),
            vocabStore: target,
            keyReader: { _ in nil },
            keyWriter: { _, _ in },
            keyDeleter: { _ in }
        )

        #expect(target.books.isEmpty)
        #expect(target.mountedIDs(forKey: VocabStore.globalMountKey).isEmpty)
        #expect(summary.vocabApplied)
        #expect(summary.vocabBooksImported == 0)
    }

    @Test("exported bundle re-imports cleanly (round trip)")
    func roundTrip() throws {
        let data = ConfigBundleExporter.bundleJSON(
            config: configWithProfiles(), vocabStore: VocabStore(defaults: freshDefaults()),
            name: "RT", includeKeys: true, keyLookup: { _ in "sk-x" })
        let vault = TestKeyVault()
        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: VocabStore(defaults: freshDefaults()),
            keyReader: vault.read, keyWriter: vault.write, keyDeleter: vault.delete)
        #expect(config.modelProfiles.count == 2)
        #expect(config.sttProfile == "stt1")
        #expect(summary.importedProfiles == 2)
        #expect(vault["stt1"] == "sk-x")
        #expect(vault["llm1"] == "sk-x")
    }
}

// MARK: - Deep link route

@MainActor
struct ConfigDeepLinkTests {

    @Test("fonos://config posts .fonosImportConfig with the URL payload")
    func configLinkPosts() async {
        let url = ConfigBundleCodec.encodeURL(bundleJSON: json(["name": "Shared"]))
        let received = OSAllocatedUnfairLock<String?>(initialState: nil)
        let token = NotificationCenter.default.addObserver(
            forName: .fonosImportConfig, object: nil, queue: .main
        ) { note in
            let payload = note.userInfo?["payload"] as? String
            received.withLock { $0 = payload }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        DeepLinkRouter.handle(url)

        let payload = received.withLock { $0 }
        #expect(payload != nil)
        // The payload decodes back to the shared bundle.
        let decoded = try? payload.map { try ConfigBundleCodec.decode($0) } ?? nil
        #expect(decoded.map { obj($0)["name"] as? String } == "Shared")
    }
}

// MARK: - ScenarioImporter preview + keys

struct ConfigImportKeyTests {

    private func apply(
        _ bundle: Data,
        to config: AppConfig = AppConfig(),
        store: VocabStore? = nil,
        vault: TestKeyVault
    ) throws -> (AppConfig, ScenarioImportSummary) {
        try ScenarioImporter.apply(
            data: bundle,
            to: config,
            vocabStore: store ?? VocabStore(defaults: freshDefaults()),
            keyReader: vault.read,
            keyWriter: vault.write,
            keyDeleter: vault.delete
        )
    }

    @Test("preview counts profiles that arrive without a key")
    func previewNeedsKeys() throws {
        let bundle = json([
            "name": "P",
            "models": ["profiles": [
                ["id": "a", "name": "A", "provider": "omlx", "model": "m"],
                ["id": "b", "name": "B", "provider": "openai", "model": "gpt", "api_key": "sk-b"],
            ]]
        ])
        let summary = try ScenarioImporter.preview(data: bundle)
        #expect(summary.importedProfiles == 2)
        #expect(summary.profilesNeedingKeys == 1)
    }

    @Test("preview does not mutate the vocab store or write keys")
    func previewNoMutation() throws {
        let bundle = json(["name": "P", "vocab": ["vocab_books": [["id": "x", "name": "X"]]]])
        _ = try ScenarioImporter.preview(data: bundle)
        // No store passed, nothing to assert on mutation beyond "did not throw";
        // the summary reflects a count without side effects.
        #expect(try ScenarioImporter.preview(data: bundle).vocabBooksImported == 1)
    }

    @Test("apply writes an embedded key through the key writer")
    func applyWritesKey() throws {
        let bundle = json([
            "name": "K",
            "models": ["profiles": [["id": "a", "name": "A", "provider": "openai", "model": "gpt", "api_key": "sk-a"]]]
        ])
        let vault = TestKeyVault()
        _ = try apply(bundle, vault: vault)
        #expect(vault["a"] == "sk-a")
    }

    @Test("a key-stripped profile changing origin deletes its stale local key")
    func changedOriginDeletesStaleKey() throws {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "a",
            name: "Old",
            provider: "openai",
            modelID: "whisper-1",
            baseURL: "https://old.example/v1",
            capabilities: ["stt"]
        )]
        let bundle = json(["models": ["profiles": [[
            "id": "a", "name": "New", "provider": "openai",
            "model": "whisper-1", "base_url": "https://new.example/v1",
            "capabilities": ["stt"],
        ]]]])
        let vault = TestKeyVault(values: ["a": "old-secret"])

        _ = try apply(bundle, to: config, vault: vault)

        #expect(vault["a"] == nil)
    }

    @Test("a key-stripped profile changing provider deletes its stale local key")
    func changedProviderDeletesStaleKey() throws {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "a", name: "Old", provider: "openai", modelID: "m",
            baseURL: "https://models.example/v1", capabilities: ["llm"]
        )]
        let bundle = json(["models": ["profiles": [[
            "id": "a", "name": "New", "provider": "custom", "model": "m",
            "base_url": "https://models.example/api", "capabilities": ["llm"],
        ]]]])
        let vault = TestKeyVault(values: ["a": "old-secret"])

        _ = try apply(bundle, to: config, vault: vault)

        #expect(vault["a"] == nil)
    }

    @Test("a key-stripped profile changing gateway path deletes its stale local key")
    func changedGatewayPathDeletesLocalKey() throws {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "a", name: "Old", provider: "openai", modelID: "old",
            baseURL: "https://models.example/v1", capabilities: ["llm"]
        )]
        let bundle = json(["models": ["profiles": [[
            "id": "a", "name": "New", "provider": "OPENAI", "model": "new",
            "base_url": "https://models.example/another/path", "capabilities": ["llm"],
        ]]]])
        let vault = TestKeyVault(values: ["a": "local-secret"])

        _ = try apply(bundle, to: config, vault: vault)

        #expect(vault["a"] == nil)
    }

    @Test("trailing slash and concrete endpoint normalize to the same credential scope")
    func equivalentServiceBasePreservesLocalKey() throws {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "a", name: "Old", provider: "openai", modelID: "whisper-1",
            baseURL: "https://models.example/tenant/", capabilities: ["stt"]
        )]
        let bundle = json(["models": ["profiles": [[
            "id": "a", "name": "New", "provider": "OPENAI", "model": "whisper-1",
            "base_url": "https://models.example/tenant/v1/audio/transcriptions/",
            "capabilities": ["stt"],
        ]]]])
        let vault = TestKeyVault(values: ["a": "local-secret"])

        _ = try apply(bundle, to: config, vault: vault)

        #expect(vault["a"] == "local-secret")
    }

    @Test("malformed vocab is rejected before any Keychain or vocab mutation")
    func malformedVocabIsRejectedAtomically() throws {
        let bundle = json([
            "models": ["profiles": [[
                "id": "a", "provider": "openai", "model": "gpt",
                "api_key": "new-secret",
            ]]],
            "vocab": ["vocab_books": "not-an-array"],
        ])
        let invalidGlobalMounts = json([
            "vocab": [
                "vocab_books": [],
                "global_vocab_books": ["valid", 42],
            ],
        ])
        let vault = TestKeyVault(values: ["a": "old-secret"])
        let store = VocabStore(defaults: freshDefaults())
        store.upsert(VocabBook(id: "phone", name: "Phone"))
        store.setMounted(["phone"], forKey: VocabStore.globalMountKey)

        #expect(throws: ScenarioImporter.ImportError.self) {
            _ = try apply(bundle, store: store, vault: vault)
        }
        #expect(throws: ScenarioImporter.ImportError.self) {
            _ = try ScenarioImporter.preview(data: invalidGlobalMounts)
        }
        #expect(vault["a"] == "old-secret")
        #expect(store.books.map(\.id) == ["phone"])
        #expect(store.mountedIDs(forKey: VocabStore.globalMountKey) == ["phone"])
    }

    @Test("credential write failure rolls back earlier keys and leaves vocabulary untouched")
    func writeFailureIsAtomic() throws {
        let bundle = json([
            "models": ["profiles": [
                ["id": "a", "provider": "openai", "model": "a", "api_key": "new-a"],
                ["id": "b", "provider": "openai", "model": "b", "api_key": "new-b"],
            ]],
            "vocab": ["vocab_books": [["id": "book", "name": "Book"]]],
        ])
        let vault = TestKeyVault(
            values: ["a": "old-a", "b": "old-b"],
            failingWrites: ["b"]
        )
        let store = VocabStore(defaults: freshDefaults())

        #expect(throws: ModelCredentialTransaction.Failure.self) {
            _ = try apply(bundle, store: store, vault: vault)
        }
        #expect(vault["a"] == "old-a")
        #expect(vault["b"] == "old-b")
        #expect(store.book(id: "book") == nil)
    }

    @Test("credential delete failure is reported and leaves vocabulary untouched")
    func deleteFailureIsReported() throws {
        var config = AppConfig()
        config.modelProfiles = [ModelProfile(
            id: "a", name: "Old", provider: "openai", modelID: "m",
            baseURL: "https://old.example", capabilities: ["llm"]
        )]
        let bundle = json([
            "models": ["profiles": [[
                "id": "a", "provider": "openai", "model": "m",
                "base_url": "https://new.example",
            ]]],
            "vocab": ["vocab_books": [["id": "book", "name": "Book"]]],
        ])
        let vault = TestKeyVault(
            values: ["a": "old-secret"],
            failingDeletes: ["a"]
        )
        let store = VocabStore(defaults: freshDefaults())

        #expect(throws: ModelCredentialTransaction.Failure.self) {
            _ = try apply(bundle, to: config, store: store, vault: vault)
        }
        #expect(vault["a"] == "old-secret")
        #expect(store.book(id: "book") == nil)
    }

    @Test("clearing an edited model creates an explicit Keychain deletion")
    func clearedModelKeyDeletesCredential() throws {
        let profile = ModelProfile(
            id: "a", name: "A", provider: "openai", modelID: "gpt",
            baseURL: "https://models.example/v1", capabilities: ["llm"]
        )
        let updates = ModelProfileForm.credentialUpdates(
            profile: profile,
            apiKey: "  \n ",
            initialProfile: profile,
            apiKeyWasEdited: true
        )
        #expect(updates == [ModelCredentialUpdate(profileID: "a", value: nil)])

        let vault = TestKeyVault(values: ["a": "secret"])
        try ModelCredentialTransaction.apply(
            updates,
            reader: vault.read,
            writer: vault.write,
            deleter: vault.delete
        )
        #expect(vault["a"] == nil)
    }

    @Test("editing a model endpoint cannot silently carry its old credential")
    func endpointChangeDeletesUnconfirmedCredential() {
        let oldProfile = ModelProfile(
            id: "a", name: "Old", provider: "openai", modelID: "gpt",
            baseURL: "https://old.example/v1", capabilities: ["llm"]
        )
        let changedProfile = ModelProfile(
            id: "a", name: "New", provider: "openai", modelID: "gpt",
            baseURL: "https://new.example/v1", capabilities: ["llm"]
        )

        let unconfirmed = ModelProfileForm.credentialUpdates(
            profile: changedProfile,
            apiKey: "old-secret",
            initialProfile: oldProfile,
            apiKeyWasEdited: false
        )
        #expect(unconfirmed == [ModelCredentialUpdate(profileID: "a", value: nil)])

        let explicitlyEntered = ModelProfileForm.credentialUpdates(
            profile: changedProfile,
            apiKey: "new-secret",
            initialProfile: oldProfile,
            apiKeyWasEdited: true
        )
        #expect(explicitlyEntered == [
            ModelCredentialUpdate(profileID: "a", value: "new-secret")
        ])
    }
}

// MARK: - ConfigSetStore

struct ConfigSetStoreTests {

    private func aSet(_ id: String, _ name: String, ts: TimeInterval) -> ConfigSet {
        ConfigSet(id: id, name: name, createdAt: Date(timeIntervalSince1970: ts),
                  bundleJSON: json(["name": name]))
    }

    @Test("save then list returns the set, newest first")
    func saveAndList() {
        let store = ConfigSetStore(defaults: freshDefaults())
        store.save(aSet("1", "Old", ts: 100))
        store.save(aSet("2", "New", ts: 200))
        #expect(store.sets.map(\.id) == ["2", "1"])
    }

    @Test("saving an existing id replaces it")
    func upsert() {
        let store = ConfigSetStore(defaults: freshDefaults())
        store.save(aSet("1", "First", ts: 100))
        store.save(aSet("1", "Renamed", ts: 100))
        #expect(store.sets.count == 1)
        #expect(store.set(id: "1")?.name == "Renamed")
    }

    @Test("delete removes the set")
    func delete() {
        let store = ConfigSetStore(defaults: freshDefaults())
        store.save(aSet("1", "A", ts: 100))
        store.delete(id: "1")
        #expect(store.sets.isEmpty)
    }

    @Test("rename changes the name")
    func rename() {
        let store = ConfigSetStore(defaults: freshDefaults())
        store.save(aSet("1", "A", ts: 100))
        store.rename(id: "1", to: "B")
        #expect(store.set(id: "1")?.name == "B")
    }

    @Test("sets persist across store instances over the same defaults")
    func persistence() {
        let defaults = freshDefaults()
        ConfigSetStore(defaults: defaults).save(aSet("1", "A", ts: 100))
        #expect(ConfigSetStore(defaults: defaults).sets.map(\.id) == ["1"])
    }
}
