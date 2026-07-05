// Main app and keyboard extension keep SEPARATE, independently-persisted
// dictation modes: the main app owns config.activeModeID; the keyboard owns
// kb_active_mode_id. Neither clobbers the other.
//
// Run: xcodebuild test -scheme FonosApp -only-testing:FonosAppTests/AppConfigStorageTests

import Testing
import Foundation
@testable import FonosApp

private func freshDefaults() -> UserDefaults {
    let name = "appconfigstorage-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func configWith(activeModeID: String) -> AppConfig {
    var c = AppConfig()
    c.activeModeID = activeModeID
    return c
}

struct AppConfigStorageTests {

    // MARK: - Separation

    @Test("saving the main-app config does not touch the keyboard mode override")
    func saveDoesNotStampKeyboardMode() {
        let standard = freshDefaults()
        let shared = freshDefaults()
        AppConfigStorage.setKeyboardModeID("polish", shared: shared)

        AppConfigStorage.save(configWith(activeModeID: "raw"), standard: standard, shared: shared)

        #expect(AppConfigStorage.keyboardModeID(shared: shared) == "polish")
    }

    @Test("loading the config does not inherit the keyboard mode override")
    func loadDoesNotInheritKeyboardMode() {
        let standard = freshDefaults()
        let shared = freshDefaults()
        AppConfigStorage.save(configWith(activeModeID: "raw"), standard: standard, shared: shared)
        AppConfigStorage.setKeyboardModeID("formal", shared: shared)

        let loaded = AppConfigStorage.load(standard: standard, shared: shared)
        #expect(loaded?.activeModeID == "raw")
    }

    @Test("a main-app mode change and a keyboard mode change persist independently")
    func independentPersistence() {
        let standard = freshDefaults()
        let shared = freshDefaults()

        // Keyboard picks "polish"
        AppConfigStorage.setKeyboardModeID("polish", shared: shared)
        // Main app later changes its own mode to "formal" and saves
        AppConfigStorage.save(configWith(activeModeID: "formal"), standard: standard, shared: shared)

        // Both survive, each on its own key.
        #expect(AppConfigStorage.load(standard: standard, shared: shared)?.activeModeID == "formal")
        #expect(AppConfigStorage.keyboardModeID(shared: shared) == "polish")
    }

    // MARK: - Keyboard mode resolution (used by BackgroundRecordingService)

    @Test("keyboard mode resolves to the override when set")
    func keyboardModeUsesOverride() {
        #expect(AppConfigStorage.resolveKeyboardMode(override: "polish", configActiveModeID: "raw") == "polish")
    }

    @Test("keyboard mode falls back to the config mode when no override is set")
    func keyboardModeFallsBack() {
        #expect(AppConfigStorage.resolveKeyboardMode(override: nil, configActiveModeID: "formal") == "formal")
        #expect(AppConfigStorage.resolveKeyboardMode(override: "", configActiveModeID: "formal") == "formal")
    }

    @Test("keyboardModeID returns nil for an empty stored value")
    func keyboardModeIDEmptyIsNil() {
        let shared = freshDefaults()
        AppConfigStorage.setKeyboardModeID("", shared: shared)
        #expect(AppConfigStorage.keyboardModeID(shared: shared) == nil)
    }
}
