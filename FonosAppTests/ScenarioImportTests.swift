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
       "base_url": "http://192.168.1.5:8000", "capabilities": ["stt"]},
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

    @Test("applies dictation mode and translate target")
    func appliesDictation() throws {
        let (config, _) = try ScenarioImporter.apply(
            data: sampleScenario, to: AppConfig(), vocabStore: freshStore())
        #expect(config.activeModeID == "polish")
        #expect(config.translateTargetLanguage == "French")
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

    @Test("skips speech and hotkeys sections")
    func skipsIOSIrrelevantSections() throws {
        let (_, summary) = try ScenarioImporter.apply(
            data: sampleScenario, to: AppConfig(), vocabStore: freshStore())
        #expect(summary.skippedSections == ["speech", "hotkeys"])
        #expect(summary.name == "Home Lab")
    }

    @Test("a scenario with no sections imports as a no-op")
    func emptyScenarioNoOp() throws {
        let data = #"{"id":"x","name":"Empty"}"#.data(using: .utf8)!
        let base = AppConfig()
        let (config, summary) = try ScenarioImporter.apply(
            data: data, to: base, vocabStore: freshStore())
        #expect(config == base)
        #expect(summary.importedProfiles == 0)
        #expect(summary.vocabBooksImported == 0)
        #expect(summary.skippedSections.isEmpty)
    }

    @Test("malformed JSON throws")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            _ = try ScenarioImporter.apply(data: Data("not json".utf8),
                                           to: AppConfig(), vocabStore: freshStore())
        }
    }
}
