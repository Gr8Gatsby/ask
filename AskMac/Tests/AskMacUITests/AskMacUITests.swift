import XCTest

// MARK: - Base test case

/// Base class for all AskMac UI tests.
///
/// Launches the app with `--uitesting` and a scenario name. The app bypasses
/// CloudKit and all subprocess startup, loading mock scripts and blocks instead.
/// The Scripts window opens automatically when `--uitesting` is active.
///
/// Viewing results:
///   - Open the test navigator → expand the failed test → "Show in Report Navigator"
///   - For CI: `xcrun xcresulttool get --format json --path build/TestResults.xcresult`
class AskMacUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
    }

    override func tearDownWithError() throws {
        screenshot("teardown")
        app?.terminate()
    }

    func launch(scenario: String) {
        app.launchEnvironment["UI_TEST_SCENARIO"] = scenario
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 5)
        screenshot("launched-\(scenario)")
    }

    // MARK: - Helpers

    var scriptsWindow: XCUIElement {
        app.windows["Ask"]
    }

    @discardableResult
    func screenshot(_ name: String) -> XCUIScreenshot {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }

    func assertExists(_ element: XCUIElement, timeout: TimeInterval = 5, _ message: String = "") {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            message.isEmpty ? "\(element) should exist" : message
        )
    }

    func assertGone(_ element: XCUIElement, timeout: TimeInterval = 3, _ message: String = "") {
        XCTAssertFalse(
            element.waitForExistence(timeout: timeout),
            message.isEmpty ? "\(element) should not exist" : message
        )
    }
}

// MARK: - Window presence

final class ScriptsWindowTests: AskMacUITestCase {

    func test_scriptsWindow_opensAutomatically() {
        launch(scenario: "confirmation")
        assertExists(scriptsWindow, timeout: 5, "Scripts window should open automatically in UI testing mode")
    }

    func test_sidebar_showsScriptName() {
        launch(scenario: "confirmation")
        let name = scriptsWindow.staticTexts["Claude Code"]
        assertExists(name, "Sidebar should show 'Claude Code' script name")
    }

    func test_sidebar_multipleScripts_bothVisible() {
        launch(scenario: "multiple_scripts")
        assertExists(scriptsWindow.staticTexts["Claude Code"], "'Claude Code' should appear in sidebar")
        assertExists(scriptsWindow.staticTexts["Codex"], "'Codex' should appear in sidebar")
    }

    func test_emptyScenario_noConfirmationButtons() {
        launch(scenario: "empty")
        let confirmBtn = scriptsWindow.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'confirm-option-'"))
            .firstMatch
        XCTAssertFalse(
            confirmBtn.waitForExistence(timeout: 2),
            "No confirmation buttons should appear in empty scenario"
        )
    }
}

// MARK: - Confirmation block — 2-option (Allow / Deny)

final class MacConfirmationBlockTests: AskMacUITestCase {

    func test_confirmationBlock_allowAndDenyVisible() {
        launch(scenario: "confirmation")
        assertExists(scriptsWindow.buttons["confirm-option-Allow"], "Allow button should be visible")
        assertExists(scriptsWindow.buttons["confirm-option-Deny"], "Deny button should be visible")
    }

    func test_confirmationBlock_tapAllow_blockClears() {
        launch(scenario: "confirmation")
        assertExists(scriptsWindow.buttons["confirm-option-Allow"])
        scriptsWindow.buttons["confirm-option-Allow"].click()
        assertGone(
            scriptsWindow.buttons["confirm-option-Allow"],
            timeout: 3,
            "Confirmation block should clear after Allow"
        )
    }

    func test_confirmationBlock_tapDeny_blockClears() {
        launch(scenario: "confirmation")
        assertExists(scriptsWindow.buttons["confirm-option-Deny"])
        scriptsWindow.buttons["confirm-option-Deny"].click()
        assertGone(
            scriptsWindow.buttons["confirm-option-Deny"],
            timeout: 3,
            "Confirmation block should clear after Deny"
        )
    }
}

// MARK: - Confirmation block — 3-option list (Always Allow)

final class MacConfirmationListBlockTests: AskMacUITestCase {

    func test_listConfirmation_threeOptions_allVisible() {
        launch(scenario: "confirmation_list")
        assertExists(scriptsWindow.buttons["confirm-option-Allow"])
        assertExists(scriptsWindow.buttons["confirm-option-Always allow Bash(npm install)"])
        assertExists(scriptsWindow.buttons["confirm-option-Deny"])
    }

    func test_listConfirmation_tapAlwaysAllow_blockClears() {
        launch(scenario: "confirmation_list")
        assertExists(scriptsWindow.buttons["confirm-option-Always allow Bash(npm install)"])
        scriptsWindow.buttons["confirm-option-Always allow Bash(npm install)"].click()
        assertGone(
            scriptsWindow.buttons["confirm-option-Always allow Bash(npm install)"],
            timeout: 3,
            "Block should clear after Always Allow"
        )
    }
}

// MARK: - Alert block

final class MacAlertBlockTests: AskMacUITestCase {

    func test_alertBlock_titleVisible() {
        launch(scenario: "alert")
        let pred = NSPredicate(format: "label CONTAINS[c] %@", "terminal-manager")
        let el = scriptsWindow.descendants(matching: .any).matching(pred).firstMatch
        assertExists(el, "Alert title should be visible in detail pane")
    }

    func test_alertBlock_bodyVisible() {
        launch(scenario: "alert")
        let pred = NSPredicate(format: "label CONTAINS[c] %@", "TUI detection")
        let el = scriptsWindow.descendants(matching: .any).matching(pred).firstMatch
        assertExists(el, "Alert body should be visible in detail pane")
    }

    func test_alertBlock_noConfirmationButtons() {
        launch(scenario: "alert")
        let confirmBtn = scriptsWindow.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'confirm-option-'"))
            .firstMatch
        XCTAssertFalse(confirmBtn.exists, "Alert blocks must not have confirmation buttons")
    }
}
