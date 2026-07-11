import Testing
import Foundation
@testable import FonosApp

/// Scaffold test suite — individual test classes go in separate files.
struct FonosAppTests {

    // P0-2 (docs/ROADMAP.md): the fonos:// URL scheme must be registered so
    // widget taps and Siri App Intents can open the app. Tests are hosted in
    // FonosApp.app, so Bundle.main is the app bundle.
    @Test func fonosURLSchemeIsRegistered() {
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains("fonos"))
    }

    @Test func appConfigDefaultValues() {
        let config = AppConfig()
        #expect(config.sttProvider == "apple")
        #expect(config.defaultMode.id == "raw")
        #expect(config.recordMode == .tap)
    }

    @Test func modeBuiltInCount() {
        #expect(Mode.builtInModes.count == 5)
    }

    @Test func rawModeDoesNotRequireLLM() {
        let raw = Mode.builtInModes.first { $0.id == "raw" }
        #expect(raw != nil)
        #expect(raw?.requiresLLM == false)
    }

    @Test func llmModesRequireLLM() {
        let llmModes = Mode.builtInModes.filter { $0.id != "raw" }
        #expect(llmModes.allSatisfy { $0.requiresLLM })
    }

    @Test func removingModelClearsDefaultsAndModeOverrides() {
        let profile = ModelProfile(
            id: "shared-model",
            name: "Shared Model",
            provider: "openai",
            modelID: "model",
            capabilities: ["stt", "llm"]
        )
        var config = AppConfig()
        config.modelProfiles = [profile]
        config.sttProfile = profile.id
        config.llmProfile = profile.id
        config.modeConfigs[1].sttModelID = profile.id
        config.modeConfigs[1].llmModelID = profile.id

        config.removeModelProfile(id: profile.id)

        #expect(config.modelProfiles.isEmpty)
        #expect(config.sttProfile.isEmpty)
        #expect(config.llmProfile.isEmpty)
        #expect(config.modeConfigs.allSatisfy { $0.sttModelID != profile.id })
        #expect(config.modeConfigs.allSatisfy { $0.llmModelID != profile.id })
    }

    @Test func danglingModeOverridesFallBackToAppDefaults() {
        let stt = ModelProfile(
            id: "default-stt",
            name: "Default STT",
            provider: "openai",
            modelID: "whisper",
            capabilities: ["stt"]
        )
        let llm = ModelProfile(
            id: "default-llm",
            name: "Default LLM",
            provider: "openai",
            modelID: "gpt",
            capabilities: ["llm"]
        )
        var config = AppConfig()
        config.modelProfiles = [stt, llm]
        config.sttProfile = stt.id
        config.llmProfile = llm.id
        config.modeConfigs[1].sttModelID = "deleted-stt"
        config.modeConfigs[1].llmModelID = "deleted-llm"

        #expect(config.effectiveSTTProfileID(forModeID: "polish") == stt.id)
        #expect(config.effectiveLLMProfileID(forModeID: "polish") == llm.id)
    }
}

// P1-4 (docs/ROADMAP.md): EN/zh-Hans localization. The String Catalog must
// compile into a zh-Hans lproj inside the app bundle with real translations.
struct LocalizationTests {

    private func zhHansBundle() -> Bundle? {
        Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test("zh-Hans localization bundle ships in the app")
    func zhHansBundleExists() {
        #expect(zhHansBundle() != nil)
    }

    @Test("core UI strings are translated to Simplified Chinese")
    func coreStringsTranslated() throws {
        let bundle = try #require(zhHansBundle())
        let cases: [(key: String, expected: String)] = [
            ("History", "历史"),
            ("Notes", "笔记"),
            ("Settings", "设置"),
            ("Tap to dictate", "点按开始听写"),
            ("Save Correction", "保存纠正"),
            ("Import Scenario", "导入场景"),
            ("Voice flow", "语音处理流程"),
            ("Flow complete", "处理流程已完成"),
            ("Transcript ready", "转写文本已就绪"),
        ]
        for (key, expected) in cases {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            #expect(value == expected, "\(key) → \(value)")
        }
    }

    @Test("app declares en and zh-Hans localizations")
    func bundleLocalizationsDeclared() {
        let declared = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] ?? []
        #expect(declared.contains("en"))
        #expect(declared.contains("zh-Hans"))
    }
}
