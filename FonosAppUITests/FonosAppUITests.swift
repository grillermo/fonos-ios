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
        XCTAssertTrue(app.staticTexts["No LLM"].waitForExistence(timeout: 3))

        XCTAssertTrue(app.buttons["Raw"].waitForExistence(timeout: 3))
        app.buttons["Raw"].tap()
        XCTAssertTrue(app.staticTexts["Raw"].waitForExistence(timeout: 3))
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
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    private func tapTab(_ title: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected \(title) tab")
        button.tap()
    }
}
