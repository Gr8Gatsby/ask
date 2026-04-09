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
        screenshot("launched-\(scenario)")
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
        // Alerts may show in the recent section — tap through to detail
        if let card = optionalCard("script-group-claudecode-controller") {
            card.tap()
        }
        step("alert title visible") {
            assertExists(
                app.staticTexts["terminal-manager not running"],
                "Alert title should be visible"
            )
        }
    }

    func test_alertBlock_bodyVisible() {
        launch(scenario: "alert")
        if let card = optionalCard("script-group-claudecode-controller") { card.tap() }
        step("alert body visible") {
            let body = app.staticTexts.matching(identifier: "alert-body").firstMatch
            assertExists(body, "Alert body should be visible")
            XCTAssert(body.label.contains("TUI detection"), "Alert body should contain expected text")
        }
    }

    func test_alertBlock_noResponseButtons() {
        launch(scenario: "alert")
        if let card = optionalCard("script-group-claudecode-controller") { card.tap() }
        let confirmBtn = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'confirm-option-'"))
            .firstMatch
        XCTAssertFalse(confirmBtn.exists, "Alert blocks must not have confirmation buttons")
    }

    private func optionalCard(_ id: String) -> XCUIElement? {
        let el = app.otherElements[id]
        return el.waitForExistence(timeout: 3) ? el : nil
    }
}

// MARK: - Agent session block

final class AgentSessionBlockTests: AskUITestCase {

    private func openDetail() {
        let card = app.otherElements["script-group-claudecode-controller"]
        assertExists(card)
        card.tap()
        screenshot("session-detail-open")
    }

    func test_agentSession_idle_projectLabelShowsCorrectName() {
        launch(scenario: "agent_session")
        openDetail()
        step("project label = 'ask'") {
            let label = app.staticTexts.matching(identifier: "agent-session-project").firstMatch
            assertExists(label, "Agent session project label should be visible")
            XCTAssertEqual(label.label, "ask", "Project label should read 'ask'")
        }
    }

    func test_agentSession_working_projectLabelPresent() {
        launch(scenario: "agent_session_working")
        openDetail()
        step("project label present while working") {
            let label = app.staticTexts.matching(identifier: "agent-session-project").firstMatch
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
