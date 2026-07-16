// Main app and keyboard extension keep separate workflow selections. The
// keyboard's legacy mode mirror remains readable for older extension builds.
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

private func configWith(activeWorkflowID: String) -> AppConfig {
    var c = WorkflowMigration.migrated(AppConfig())
    c.activeVoiceWorkflowID = activeWorkflowID
    return c
}

struct AppConfigStorageTests {

    // MARK: - Separation

    @Test("saving the main-app config does not touch the keyboard mode override")
    func saveDoesNotStampKeyboardMode() {
        let standard = freshDefaults()
        let shared = freshDefaults()
        AppConfigStorage.setKeyboardModeID("polish", shared: shared)

        AppConfigStorage.save(
            configWith(activeWorkflowID: "wf.dictation"),
            standard: standard,
            shared: shared
        )

        #expect(AppConfigStorage.keyboardModeID(shared: shared) == "polish")
    }

    @Test("loading the config does not inherit the keyboard mode override")
    func loadDoesNotInheritKeyboardMode() {
        let standard = freshDefaults()
        let shared = freshDefaults()
        AppConfigStorage.save(
            configWith(activeWorkflowID: "wf.dictation"),
            standard: standard,
            shared: shared
        )
        AppConfigStorage.setKeyboardModeID("formal", shared: shared)

        let loaded = AppConfigStorage.load(standard: standard, shared: shared)
        #expect(loaded?.activeVoiceWorkflowID == "wf.dictation")
    }

    @Test("a main-app mode change and a keyboard mode change persist independently")
    func independentPersistence() {
        let standard = freshDefaults()
        let shared = freshDefaults()

        // Keyboard picks "polish"
        AppConfigStorage.setKeyboardModeID("polish", shared: shared)
        // Main app later changes its own mode to "formal" and saves
        AppConfigStorage.save(
            configWith(activeWorkflowID: "wf.voice.formal"),
            standard: standard,
            shared: shared
        )

        // Both survive, each on its own key.
        #expect(AppConfigStorage.load(standard: standard, shared: shared)?
            .activeVoiceWorkflowID == "wf.voice.formal")
        #expect(AppConfigStorage.keyboardModeID(shared: shared) == "polish")
    }

    @Test("keyboardModeID returns nil for an empty stored value")
    func keyboardModeIDEmptyIsNil() {
        let shared = freshDefaults()
        AppConfigStorage.setKeyboardModeID("", shared: shared)
        #expect(AppConfigStorage.keyboardModeID(shared: shared) == nil)
    }

    @Test("keyboard workflow override is stored independently from the legacy mode mirror")
    func keyboardWorkflowOverrideIsIndependent() {
        let shared = freshDefaults()
        AppConfigStorage.setKeyboardModeID("polish", shared: shared)
        AppConfigStorage.setKeyboardWorkflowID("wf.custom-demo", shared: shared)

        #expect(AppConfigStorage.keyboardModeID(shared: shared) == "polish")
        #expect(AppConfigStorage.keyboardWorkflowID(shared: shared) == "wf.custom-demo")
    }

    @Test("saving publishes only operationally runnable recipes to the keyboard")
    func savePublishesValidatedKeyboardManifest() throws {
        let standard = freshDefaults()
        let shared = freshDefaults()
        var config = WorkflowMigration.migrated(AppConfig())
        let invalidSTT = WorkflowWidget(
            id: "stt.missing-profile",
            role: .processor,
            typeTag: "stt",
            name: "Missing",
            props: .object(["model_profile": .string("ghost")])
        )
        config.widgets.append(invalidSTT)
        config.workflows.append(WorkflowDefinition(
            id: "wf.invalid-profile",
            name: "Invalid",
            source: "src.mic-hold",
            processors: [invalidSTT.id],
            outputs: ["out.insert"]
        ))

        AppConfigStorage.save(config, standard: standard, shared: shared)

        let data = try #require(shared.data(forKey: AppConfigStorage.keyboardWorkflowManifestKey))
        let manifest = try JSONDecoder().decode([KeyboardIPC.WorkflowManifestEntry].self, from: data)
        #expect(manifest.contains { $0.id == "wf.dictation" })
        #expect(!manifest.contains { $0.id == "wf.invalid-profile" })
    }

    @Test("keyboard manifest accepts Apple sentinel and preserves a valid empty state")
    func keyboardManifestSentinelAndEmptyState() {
        var appleConfig = WorkflowMigration.migrated(AppConfig())
        let appleSTT = WorkflowWidget(
            id: "stt.apple",
            role: .processor,
            typeTag: "stt",
            name: "Apple",
            props: .object(["model_profile": .string(ModelProfileReference.appleSpeech)])
        )
        appleConfig.widgets.append(appleSTT)
        appleConfig.workflows.append(WorkflowDefinition(
            id: "wf.apple",
            name: "Apple",
            source: "src.mic-hold",
            processors: [appleSTT.id],
            outputs: ["out.insert"]
        ))
        #expect(AppConfigStorage.keyboardWorkflowManifest(config: appleConfig)
            .contains { $0.id == "wf.apple" })

        var unavailable = appleConfig
        unavailable.widgets.append(contentsOf: [
            WorkflowWidget(
                id: "src.mic-hold", role: .output, typeTag: "clipboard", name: "Broken"
            ),
            WorkflowWidget(
                id: "src.mic-toggle", role: .output, typeTag: "clipboard", name: "Broken"
            )
        ])
        #expect(AppConfigStorage.keyboardWorkflowManifest(config: unavailable).isEmpty)
    }
}
