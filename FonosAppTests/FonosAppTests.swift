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
