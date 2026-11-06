import XCTest

final class FonosAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
    }

    @MainActor
    func testAppLaunches() throws {
        let app = launchApp()

        // Verify the app launches and the root window is present
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    @MainActor
    func testTabBarExists() throws {
        let app = launchApp()

        // Verify a tab bar is present in the launched app
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Expected a tab bar to exist")
    }

    @MainActor
    func testPrimaryTabsNavigate() throws {
        let app = launchApp()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), "Expected a tab bar to exist")

        tapTab("History", in: app)
        XCTAssertTrue(app.staticTexts["No dictation history yet."].waitForExistence(timeout: 3))

        tapTab("Notes", in: app)
        XCTAssertTrue(app.staticTexts["New Notebook"].waitForExistence(timeout: 3))

        tapTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Models"].waitForExistence(timeout: 3))

        tapTab("Dictate", in: app)
        XCTAssertTrue(app.staticTexts["Tap to dictate"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testModeSelectionUpdatesModelBadge() throws {
        let app = launchApp()

        XCTAssertTrue(app.buttons["Formal"].waitForExistence(timeout: 5))
        app.buttons["Formal"].tap()

        XCTAssertTrue(app.staticTexts["Formal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["flow-progress"].waitForExistence(timeout: 3))

        XCTAssertTrue(app.buttons["Raw"].waitForExistence(timeout: 3))
        app.buttons["Raw"].tap()
        XCTAssertTrue(app.staticTexts["Raw"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testFlowSurfacesAreVisible() throws {
        let app = launchApp()

        let dictateFlow = app.descendants(matching: .any)["flow-progress"]
        XCTAssertTrue(
            dictateFlow.waitForExistence(timeout: 5),
            "Expected the post-capture Flow strip on Dictate"
        )

        tapTab("Settings", in: app)
        let modesButton = app.buttons["Modes"]
        XCTAssertTrue(modesButton.waitForExistence(timeout: 3))
        modesButton.tap()

        let overview = app.descendants(matching: .any)["modes.voiceFlowOverview"]
        XCTAssertTrue(
            overview.waitForExistence(timeout: 3),
            "Expected the Voice flow overview in Settings → Modes"
        )
    }

    @MainActor
    func testRecordButtonStartsPermissionOrRecordingFlow() throws {
        let app = launchApp()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let recordButton = app.descendants(matching: .any)["record-button"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 5), "Expected record button to be accessible")

        recordButton.tap()

        let permissionAlert = springboard.alerts.firstMatch
        let recordingText = app.staticTexts["Tap to stop"]
        let errorText = app.staticTexts["Error"]
        let processingText = app.staticTexts["Processing..."]

        let reachedRecordFlow = permissionAlert.waitForExistence(timeout: 3)
            || recordingText.waitForExistence(timeout: 1)
            || processingText.waitForExistence(timeout: 1)
            || errorText.waitForExistence(timeout: 1)

        XCTAssertTrue(reachedRecordFlow, "Expected tapping record to trigger permissions, recording, processing, or an error state")
        if permissionAlert.exists {
            let dismissButton = permissionAlert.buttons.firstMatch
            if dismissButton.waitForExistence(timeout: 1) {
                dismissButton.tap()
            }
        }
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let configuredDir = ProcessInfo.processInfo.environment["FONOS_SCREENSHOT_DIR"]
        let outputDir = configuredDir.flatMap { value in
            value.isEmpty || value.hasPrefix("$(") ? nil : value
        } ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("release/app-store/screenshots/iphone-17-pro-max")
            .path

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir), withIntermediateDirectories: true
        )

        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        dismissSystemAlertIfPresent(for: app)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo Whisper STT"].waitForExistence(timeout: 3))

        capture("01-dictate", app: app, outputDir: outputDir)

        tapTab("History", in: app)
        let launchChecklist = app.staticTexts[
            "Please send the launch checklist to Maya and ask her to review the privacy labels before Friday."
        ]
        XCTAssertTrue(launchChecklist.waitForExistence(timeout: 3))
        capture("02-history", app: app, outputDir: outputDir)

        tapTab("Notes", in: app)
        XCTAssertTrue(app.staticTexts["Launch Notes"].waitForExistence(timeout: 3))
        capture("03-notes", app: app, outputDir: outputDir)

        tapTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        let generalButton = app.buttons["General"]
        XCTAssertTrue(generalButton.waitForExistence(timeout: 3))
        generalButton.tap()
        XCTAssertTrue(app.staticTexts["Start Keyboard Ready"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Privacy & Data Sharing"].waitForExistence(timeout: 3))
        capture("04-settings", app: app, outputDir: outputDir)
    }

    @MainActor
    func testTappingNoteAppendsToIt() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Notes", in: app)

        let notebook = app.staticTexts["Ideas"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Expected the seeded notebook")
        notebook.tap()

        let note = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "quick mode switch")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Expected the seeded note")
        note.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Expected the note editor")
        XCTAssertTrue((editor.value as? String)?.contains("quick mode switch") == true)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Expected editor focus")

        editor.typeText(" Appended words")
        app.navigationBars["Edit Note"].buttons["Done"].tap()

        let updated = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Appended words")
        ).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 5), "Expected the row to show the appended text")
    }

    @MainActor
    func testOpenNoteOffersTheMicrophone() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Notes", in: app)

        let notebook = app.staticTexts["Ideas"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Expected the seeded notebook")
        notebook.tap()

        let note = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "quick mode switch")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Expected the seeded note")
        note.tap()

        XCTAssertTrue(app.navigationBars["Edit Note"].waitForExistence(timeout: 5))
        // The notebook's own microphone stays in the tree behind the sheet.
        let mics = app.buttons.matching(identifier: "noteRecordButton")
        XCTAssertTrue(mics.firstMatch.waitForExistence(timeout: 5), "Expected the microphone in the open note")
        let mic = try XCTUnwrap(
            mics.allElementsBoundByIndex.last(where: \.isHittable),
            "Expected a reachable microphone in the open note"
        )
        mic.tap()

        XCTAssertTrue(
            app.staticTexts["Recording to"].waitForExistence(timeout: 5),
            "Expected the record sheet over the open note"
        )
    }

    /// The Install Latest scene delegate must leave `fonos://` links reaching
    /// SwiftUI's `onOpenURL`, which the widget and Siri depend on.
    @MainActor
    func testDeepLinkReachesTheApp() throws {
        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        let url = try XCTUnwrap(URL(string: "fonos://model?name=mema-test&base_url=http://192.168.1.3:8787&model=parakeet"))
        app.open(url)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) {
            open.tap()
        }

        XCTAssertTrue(
            app.navigationBars["Import Config"].waitForExistence(timeout: 5),
            "Expected the model link to open the import sheet"
        )
    }

    // MARK: - "Record a Note" must reach the recorder from any state

    @MainActor
    func testNoteLinkRecordsFromAnotherTab() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Settings", in: app)
        XCUIDevice.shared.press(.home)

        openNoteLink(in: app)

        assertRecordSheetOpens(in: app, "from the Settings tab")
    }

    @MainActor
    func testNoteLinkRecordsOverAnOpenNotebook() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Notes", in: app)
        let notebook = app.staticTexts["Ideas"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Expected the seeded notebook")
        notebook.tap()
        XCTAssertTrue(app.buttons["noteRecordButton"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)

        openNoteLink(in: app)

        assertRecordSheetOpens(in: app, "over a notebook opened by hand")
    }

    @MainActor
    func testNoteLinkRecordsOverAnOpenNoteEditor() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Notes", in: app)
        let notebook = app.staticTexts["Ideas"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Expected the seeded notebook")
        notebook.tap()
        let note = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "quick mode switch")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Expected the seeded note")
        note.tap()
        XCTAssertTrue(app.navigationBars["Edit Note"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)

        openNoteLink(in: app)

        assertRecordSheetOpens(in: app, "over an open note editor")
    }

    @MainActor
    func testNoteLinkRecordsEveryTime() throws {
        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        openNoteLink(in: app)
        assertRecordSheetOpens(in: app, "on the first run")
        dismissRecordSheet(in: app)
        XCUIDevice.shared.press(.home)

        openNoteLink(in: app)
        assertRecordSheetOpens(in: app, "on the second run")
    }

    @MainActor
    func testNoteLinkDoesNotReplayWhenLeavingTheNotebook() throws {
        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        openNoteLink(in: app)
        assertRecordSheetOpens(in: app, "on the first run")
        dismissRecordSheet(in: app)

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()

        XCTAssertTrue(app.staticTexts["New Notebook"].waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts["Recording to"].waitForExistence(timeout: 2),
            "Going back must not start another recording"
        )
        XCTAssertTrue(app.staticTexts["New Notebook"].isHittable, "Expected to stay on the notebook grid")
    }

    @MainActor
    func testNoteLinkDoesNotReplayWhenSwitchingTabs() throws {
        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        openNoteLink(in: app)
        assertRecordSheetOpens(in: app, "on the first run")
        dismissRecordSheet(in: app)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["New Notebook"].waitForExistence(timeout: 5))
        tapTab("Settings", in: app)
        tapTab("Notes", in: app)

        XCTAssertFalse(
            app.staticTexts["Recording to"].waitForExistence(timeout: 2),
            "Returning to the Notes tab must not start another recording"
        )
    }

    // MARK: - The real App Intent, run from the Shortcuts app

    @MainActor
    func testRecordNoteShortcutFromColdStart() throws {
        let app = XCUIApplication()
        app.terminate()

        runRecordNoteShortcut()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertRecordSheetOpens(in: app, "from a cold start")
    }

    @MainActor
    func testRecordNoteShortcutFromAnotherTab() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Settings", in: app)

        runRecordNoteShortcut()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertRecordSheetOpens(in: app, "from the Settings tab")
    }

    @MainActor
    func testRecordNoteShortcutOverAnOpenNotebook() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Notes", in: app)
        let notebook = app.staticTexts["Ideas"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Expected the seeded notebook")
        notebook.tap()
        XCTAssertTrue(app.buttons["noteRecordButton"].waitForExistence(timeout: 5))

        runRecordNoteShortcut()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertRecordSheetOpens(in: app, "over a notebook opened by hand")
    }

    @MainActor
    func testRecordNoteShortcutOverAnOpenNoteEditor() throws {
        let app = launchApp(screenshotMode: true)
        tapTab("Notes", in: app)
        let notebook = app.staticTexts["Ideas"]
        XCTAssertTrue(notebook.waitForExistence(timeout: 5), "Expected the seeded notebook")
        notebook.tap()
        let note = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "quick mode switch")
        ).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Expected the seeded note")
        note.tap()
        XCTAssertTrue(app.navigationBars["Edit Note"].waitForExistence(timeout: 5))

        runRecordNoteShortcut()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertRecordSheetOpens(in: app, "over an open note editor")
    }

    @MainActor
    func testRecordNoteShortcutRecordsEveryTime() throws {
        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

        runRecordNoteShortcut()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertRecordSheetOpens(in: app, "on the first run")
        dismissRecordSheet(in: app)

        runRecordNoteShortcut()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        assertRecordSheetOpens(in: app, "on the second run")
    }

    @MainActor
    private func runRecordNoteShortcut() {
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.activate()
        let tile = shortcuts.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Record Note")
        ).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Expected Fonos's Record Note tile in Shortcuts")
        tile.tap()
    }

    @MainActor
    private func openNoteLink(in app: XCUIApplication) {
        app.open(URL(string: "fonos://note")!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 2) {
            open.tap()
        }
    }

    @MainActor
    private func assertRecordSheetOpens(in app: XCUIApplication, _ situation: String) {
        XCTAssertTrue(
            app.staticTexts["Recording to"].waitForExistence(timeout: 5),
            "Expected the record sheet \(situation)"
        )
    }

    /// The simulator has no microphone, so capture ends on the error state.
    @MainActor
    private func dismissRecordSheet(in app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "Expected the sheet's Dismiss button")
        dismiss.tap()
        XCTAssertTrue(app.buttons["noteRecordButton"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchApp(screenshotMode: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if screenshotMode {
            app.launchEnvironment["FONOS_SCREENSHOT_MODE"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    private func tapTab(_ title: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected \(title) tab")
        button.tap()
    }

    @MainActor
    private func dismissSystemAlertIfPresent(for app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return }
        let dismissButton = alert.buttons.firstMatch
        if dismissButton.waitForExistence(timeout: 1) {
            dismissButton.tap()
            app.activate()
        }
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication, outputDir: String) {
        // SwiftUI's tab transition can leave the native tab bar midway through
        // its layout animation even after the destination content exists.
        // Let the run loop settle so App Store assets never capture that frame.
        for title in ["Dictate", "History", "Notes", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[title].waitForExistence(timeout: 3))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url, options: [.atomic])
        } catch {
            XCTFail("Failed to write \(url.path): \(error)")
        }
    }
}
