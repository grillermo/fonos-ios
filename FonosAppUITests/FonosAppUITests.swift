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
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        guard let outputDir = ProcessInfo.processInfo.environment["FONOS_SCREENSHOT_DIR"],
              !outputDir.isEmpty else {
            throw XCTSkip("Set FONOS_SCREENSHOT_DIR to generate App Store screenshots.")
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputDir), withIntermediateDirectories: true
        )

        let app = launchApp(screenshotMode: true)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Demo Whisper STT"].waitForExistence(timeout: 3))

        capture("01-dictate", outputDir: outputDir)

        tapTab("History", in: app)
        XCTAssertTrue(app.staticTexts["Please send the launch checklist to Maya and ask her to review the privacy labels before Friday."].waitForExistence(timeout: 3))
        capture("02-history", outputDir: outputDir)

        tapTab("Notes", in: app)
        XCTAssertTrue(app.staticTexts["Launch Notes"].waitForExistence(timeout: 3))
        capture("03-notes", outputDir: outputDir)

        tapTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Demo Whisper STT"].waitForExistence(timeout: 3))
        capture("04-settings", outputDir: outputDir)
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
    private func capture(_ name: String, outputDir: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = URL(fileURLWithPath: outputDir).appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url, options: [.atomic])
        } catch {
            XCTFail("Failed to write \(url.path): \(error)")
        }
    }
}
