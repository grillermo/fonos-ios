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

/// Thread-safe capture for the @Sendable key writer used by ScenarioImporter.
private final class KeyCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var dict: [String: String] = [:]
    func write(_ id: String, _ key: String) { lock.withLock { dict[id] = key } }
    subscript(_ id: String) -> String? { lock.withLock { dict[id] } }
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

    @Test("exported bundle re-imports cleanly (round trip)")
    func roundTrip() throws {
        let data = ConfigBundleExporter.bundleJSON(
            config: configWithProfiles(), vocabStore: VocabStore(defaults: freshDefaults()),
            name: "RT", includeKeys: true, keyLookup: { _ in "sk-x" })
        let captured = KeyCapture()
        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: AppConfig(), vocabStore: VocabStore(defaults: freshDefaults()),
            keyWriter: { id, key in captured.write(id, key) })
        #expect(config.modelProfiles.count == 2)
        #expect(config.sttProfile == "stt1")
        #expect(summary.importedProfiles == 2)
        #expect(captured["stt1"] == "sk-x")
        #expect(captured["llm1"] == "sk-x")
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
        let captured = KeyCapture()
        _ = try ScenarioImporter.apply(data: bundle, to: AppConfig(),
                                       vocabStore: VocabStore(defaults: freshDefaults()),
                                       keyWriter: { id, key in captured.write(id, key) })
        #expect(captured["a"] == "sk-a")
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
