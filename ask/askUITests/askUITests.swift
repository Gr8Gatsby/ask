import XCTest

// MARK: - Base test case

/// Base class for all Ask UI tests.
///
/// Launches the app with `--uitesting` and a scenario name. Screenshots are
/// attached at key moments so the Xcode result bundle is self-documenting.
/// Xcode also captures a screenshot automatically on every assertion failure.
///
/// Viewing results:
///   - Open the test navigator → expand the failed test → click "Show in Report Navigator"
///   - All attached screenshots and screen recordings appear inline.
///   - For CI: `xcrun xcresulttool get --format json --path build/TestResults.xcresult`
///     extracts all attachments including screenshots and video clips.
class AskUITestCase: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]

        // Dismiss any Springboard-level dialogs left over from a previous test
        // (e.g. Apple Account Verification that persists across app launches).
        dismissSystemAlerts()

        // Also handle in-session interruptions (location, push, etc.).
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            let dismissLabels = ["Not Now", "Cancel", "Later", "Skip", "Dismiss"]
            for label in dismissLabels {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        screenshot("teardown")
        app?.terminate()
    }

    /// Launch the app pre-loaded with a named mock scenario.
    func launch(scenario: String) {
        app.launchEnvironment["UI_TEST_SCENARIO"] = scenario
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 5)
        // The iCloud dialog can appear asynchronously after the app starts.
        // app.activate() triggers any pending interruption monitors, then we do
        // an explicit Springboard check for dialogs that show over the app.
        app.activate()
        dismissSystemAlerts()
        screenshot("launched-\(scenario)")
    }

    /// Dismisses Springboard-level system dialogs (e.g. "Apple Account Verification").
    /// These are OS overlays that appear before test interactions and won't be caught
    /// by addUIInterruptionMonitor alone. Tapping "Not Now" / "Cancel" keeps the
    /// simulator clean without requiring a simulator iCloud account.
    ///
    /// Retries several times to handle dialogs that appear sequentially or asynchronously.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let pred = NSPredicate(format: "label IN %@", ["Not Now", "Cancel", "Later", "Skip", "Dismiss"])
        // Try up to 3 rounds — each round waits up to 1.5 s for a dialog button to appear.
        for _ in 0..<3 {
            let btn = springboard.buttons.matching(pred).firstMatch
            guard btn.waitForExistence(timeout: 1.5) else { break }
            btn.tap()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Screenshot helpers

    @discardableResult
    func screenshot(_ name: String) -> XCUIScreenshot {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }

    func step(_ name: String, action: () throws -> Void) rethrows {
        try XCTContext.runActivity(named: name) { _ in
            screenshot("\(name)-before")
            try action()
            screenshot("\(name)-after")
        }
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

    /// Finds a script group card by id, regardless of whether it renders as a button (Recent section)
    /// or an other/container element (Needs Response section).
    func scriptGroupCard(_ id: String) -> XCUIElement {
        let pred = NSPredicate(format: "identifier == %@", id)
        let other = app.otherElements.matching(pred).firstMatch
        if other.waitForExistence(timeout: 3) { return other }
        return app.buttons.matching(pred).firstMatch
    }
}

// MARK: - Home screen tests

final class HomeScreenTests: AskUITestCase {

    func test_homeScreen_showsScriptGroupForConfirmationScenario() {
        launch(scenario: "confirmation")
        step("script group card present") {
            assertExists(
                app.otherElements["script-group-claudecode-controller"],
                "Claude Code script group card should appear"
            )
        }
    }

    func test_homeScreen_needsResponseSectionVisible_whenInboxBlockExists() {
        launch(scenario: "confirmation")
        step("Needs Response header visible") {
            assertExists(
                app.staticTexts["Needs Response"],
                "'Needs Response' header should appear when inbox blocks exist"
            )
        }
    }

    func test_homeScreen_multipleScripts_bothGroupsVisible() {
        launch(scenario: "multiple_scripts")
        step("both script groups visible") {
            assertExists(app.otherElements["script-group-claudecode-controller"])
            assertExists(app.otherElements["script-group-codex-2"])
        }
    }

    func test_homeScreen_emptyScenario_noNeedsResponseSection() {
        launch(scenario: "empty")
        let header = app.staticTexts["Needs Response"]
        XCTAssertFalse(
            header.waitForExistence(timeout: 2),
            "'Needs Response' should not appear when there are no inbox blocks"
        )
        screenshot("empty-state")
    }
}

// MARK: - Confirmation block — 2-option (Allow / Deny)

final class ConfirmationBlockTests: AskUITestCase {

    private func openConfirmationDetail(scriptID: String = "claudecode-controller") {
        let card = app.otherElements["script-group-\(scriptID)"]
        assertExists(card, "Script group card must be visible before tap")
        card.tap()
        screenshot("detail-open")
    }

    func test_confirmationBlock_twoOptions_bothVisible() {
        launch(scenario: "confirmation")
        openConfirmationDetail()
        step("both options present") {
            assertExists(app.buttons["confirm-option-Allow"], "Allow button should be visible")
            assertExists(app.buttons["confirm-option-Deny"], "Deny button should be visible")
        }
    }

    func test_confirmationBlock_tapAllow_blockClears() {
        launch(scenario: "confirmation")
        openConfirmationDetail()
        step("tap Allow") {
            app.buttons["confirm-option-Allow"].tap()
        }
        step("block cleared") {
            assertGone(app.buttons["confirm-option-Allow"], timeout: 3,
                       "Confirmation block should clear after Allow")
        }
    }

    func test_confirmationBlock_tapDeny_blockClears() {
        launch(scenario: "confirmation")
        openConfirmationDetail()
        step("tap Deny") {
            app.buttons["confirm-option-Deny"].tap()
        }
        step("block cleared") {
            assertGone(app.buttons["confirm-option-Deny"], timeout: 3,
                       "Confirmation block should clear after Deny")
        }
    }
}

// MARK: - Confirmation block — 3-option list (Always Allow)

final class ConfirmationListBlockTests: AskUITestCase {

    private func openConfirmationDetail() {
        let card = app.otherElements["script-group-claudecode-controller"]
        assertExists(card)
        card.tap()
        screenshot("list-detail-open")
    }

    func test_listConfirmation_threeOptions_allVisible() {
        launch(scenario: "confirmation_list")
        openConfirmationDetail()
        step("all three options present") {
            assertExists(app.buttons["confirm-option-Allow"])
            assertExists(app.buttons["confirm-option-Always allow Bash(npm install)"])
            assertExists(app.buttons["confirm-option-Deny"])
        }
    }

    func test_listConfirmation_tapAlwaysAllow_blockClears() {
        launch(scenario: "confirmation_list")
        openConfirmationDetail()
        step("tap Always Allow") {
            app.buttons["confirm-option-Always allow Bash(npm install)"].tap()
        }
        step("block cleared") {
            assertGone(
                app.buttons["confirm-option-Always allow Bash(npm install)"],
                timeout: 3,
                "Block should clear after Always Allow"
            )
        }
    }
}

// MARK: - Alert block

final class AlertBlockTests: AskUITestCase {

    func test_alertBlock_titleVisible() {
        launch(scenario: "alert")
        // Alerts show in the recent section — tap through to detail
        let card = scriptGroupCard("script-group-claudecode-controller")
        assertExists(card, "Script group card must be visible")
        card.tap()
        step("alert title visible") {
            // List cells with non-interactive content collapse to a single element whose label
            // is the concatenation of child text. Match on label text.
            let pred = NSPredicate(format: "label CONTAINS[c] %@", "terminal-manager")
            let el = app.descendants(matching: .any).matching(pred).firstMatch
            assertExists(el, "Alert title should be visible")
        }
    }

    func test_alertBlock_bodyVisible() {
        launch(scenario: "alert")
        let card = scriptGroupCard("script-group-claudecode-controller")
        assertExists(card, "Script group card must be visible")
        card.tap()
        step("alert body visible") {
            let pred = NSPredicate(format: "label CONTAINS[c] %@", "TUI detection")
            let el = app.descendants(matching: .any).matching(pred).firstMatch
            assertExists(el, "Alert body should be visible")
        }
    }

    func test_alertBlock_noResponseButtons() {
        launch(scenario: "alert")
        let card = scriptGroupCard("script-group-claudecode-controller")
        assertExists(card, "Script group card must be visible")
        card.tap()
        let confirmBtn = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'confirm-option-'"))
            .firstMatch
        XCTAssertFalse(confirmBtn.exists, "Alert blocks must not have confirmation buttons")
    }
}

// MARK: - Agent session block

final class AgentSessionBlockTests: AskUITestCase {

    private func openDetail() {
        let card = scriptGroupCard("script-group-claudecode-controller")
        assertExists(card)
        card.tap()
        screenshot("session-detail-open")
    }

    func test_agentSession_idle_projectLabelShowsCorrectName() {
        launch(scenario: "agent_session")
        openDetail()
        step("session row shows project name 'ask'") {
            // session-row-project is the project Text in SessionRowView (visible in ScriptDetailView list)
            let label = app.staticTexts.matching(identifier: "session-row-project").firstMatch
            assertExists(label, "Agent session project label should be visible")
            XCTAssertEqual(label.label, "ask", "Project label should read 'ask'")
        }
    }

    func test_agentSession_working_projectLabelPresent() {
        launch(scenario: "agent_session_working")
        openDetail()
        step("session row shows project name while working") {
            let label = app.staticTexts.matching(identifier: "session-row-project").firstMatch
            assertExists(label)
            XCTAssertEqual(label.label, "ask")
        }
    }
}

// MARK: - Launch performance

final class AskLaunchPerformanceTests: XCTestCase {
    func test_launchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting"]
            app.launchEnvironment["UI_TEST_SCENARIO"] = "confirmation"
            app.launch()
            app.terminate()
        }
    }
}
