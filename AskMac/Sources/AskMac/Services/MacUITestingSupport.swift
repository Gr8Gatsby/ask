#if DEBUG
import AppKit
import Foundation

// MARK: - UI Test mode detection

/// Mac-side UI testing support. Mirrors the iOS UITestingSupport pattern.
///
/// Launch the app with `--uitesting` and set `UI_TEST_SCENARIO` to select mock data:
///
///   app.launchArguments = ["--uitesting"]
///   app.launchEnvironment["UI_TEST_SCENARIO"] = "confirmation"
///   app.launch()
///
/// The app bypasses all CloudKit and subprocess startup, injecting mock scripts
/// and blocks so tests run without a real iCloud account or running scripts.
enum MacUITestingSupport {

    static var isUITesting: Bool {
        CommandLine.arguments.contains("--uitesting")
    }

    static var scenario: String {
        ProcessInfo.processInfo.environment["UI_TEST_SCENARIO"] ?? "confirmation"
    }

    // MARK: - Responded block tracking

    /// Block IDs that have been dismissed — filtered out on subsequent fetches
    /// so the UI reflects dismissal even if something triggers a reload.
    private(set) static var respondedBlockIDs: Set<String> = []

    static func markResponded(_ blockID: String) {
        respondedBlockIDs.insert(blockID)
    }

    // MARK: - Mock scripts per scenario

    static func scripts(for scenario: String) -> [ManagedScript] {
        switch scenario {
        case "codex_permission":
            return [mockScript(id: "codex-3", name: "Codex 3")]
        case "multiple_scripts":
            return [
                mockScript(id: "claudecode-controller", name: "Claude Code"),
                mockScript(id: "codex-2", name: "Codex"),
            ]
        case "empty":
            return []
        default:
            return [mockScript(id: "claudecode-controller", name: "Claude Code")]
        }
    }

    // MARK: - Mock blocks per scenario

    static func activeBlocks(for scenario: String) -> [String: [String: LiveBlock]] {
        var result: [String: [String: LiveBlock]] = [:]
        for block in allMockBlocks(for: scenario) {
            guard !respondedBlockIDs.contains(block.id) else { continue }
            result[block.scriptID, default: [:]][block.id] = LiveBlock(
                id: block.id,
                blockType: block.blockType,
                payloadJSON: block.payloadJSON,
                createdAt: Date(),
                requiresResponse: block.blockType != "tile",
                showsInInbox: block.blockType == "confirmation"
            )
        }
        return result
    }

    // MARK: - Private helpers

    private struct MockBlock {
        let id: String
        let scriptID: String
        let blockType: String
        let payloadJSON: String
    }

    // swiftlint:disable function_body_length
    private static func allMockBlocks(for scenario: String) -> [MockBlock] {
        switch scenario {

        case "confirmation":
            return [
                MockBlock(
                    id: "mock-confirmation-1",
                    scriptID: "claudecode-controller",
                    blockType: "confirmation",
                    payloadJSON: #"{"title":"Allow Bash?","body":"git status","options":["Allow","Deny"],"urgency":"urgent"}"#
                ),
            ]

        case "confirmation_list":
            return [
                MockBlock(
                    id: "mock-confirmation-list-1",
                    scriptID: "claudecode-controller",
                    blockType: "confirmation",
                    payloadJSON: #"{"title":"Allow Bash?","body":"npm install","options":["Allow","Always allow Bash(npm install)","Deny"],"urgency":"urgent","style":"list"}"#
                ),
            ]

        case "alert":
            return [
                MockBlock(
                    id: "mock-alert-1",
                    scriptID: "claudecode-controller",
                    blockType: "alert",
                    payloadJSON: #"{"title":"terminal-manager not running","body":"TUI detection is unavailable. Start terminal-manager to enable interactive prompts on iPhone.","urgency":"warning"}"#
                ),
            ]

        case "codex_permission":
            return [
                MockBlock(
                    id: "mock-codex-session-1",
                    scriptID: "codex-3",
                    blockType: "agent_session",
                    payloadJSON: #"{"agent_name":"Codex 3","project":"ask","is_working":true,"last_message":"Working…","current_preview":"git commit -m \"Fix routing\"","status_text":"Waiting Permission","placeholder":"Message Codex 3…","pending_confirmation":{"title":"Allow Bash?","options":["Allow","Always Allow","Deny"]}}"#
                )
            ]

        case "multiple_scripts":
            return [
                MockBlock(
                    id: "block-1",
                    scriptID: "claudecode-controller",
                    blockType: "confirmation",
                    payloadJSON: #"{"title":"Allow Read?","body":"~/Documents/notes.txt","options":["Allow","Deny"],"urgency":"urgent"}"#
                ),
                MockBlock(
                    id: "block-2",
                    scriptID: "codex-2",
                    blockType: "confirmation",
                    payloadJSON: #"{"title":"Allow Bash?","body":"npm test","options":["Allow","Deny"],"urgency":"warning"}"#
                ),
            ]

        case "empty":
            return []

        default:
            return []
        }
    }
    // swiftlint:enable function_body_length

    private static func mockScript(id: String, name: String) -> ManagedScript {
        ManagedScript(
            id: id,
            name: name,
            version: "1.0.0",
            description: nil,
            icon: "terminal",
            iconImage: nil,
            svgString: nil,
            status: .running,
            isEnabled: true,
            lastError: nil,
            lastEmitTime: Date(),
            scriptType: nil,
            schedule: nil,
            entry: nil,
            manifestPath: nil,
            setupScript: nil
        )
    }
}
#endif
