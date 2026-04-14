import Foundation

// MARK: - UI Test mode detection

/// Lightweight test-mode helper. Add `--uitesting` to the app's launch arguments
/// in the XCUITest target, and optionally set `UI_TEST_SCENARIO` in launch environment.
///
/// Example (in XCUITest):
///   app.launchArguments = ["--uitesting"]
///   app.launchEnvironment = ["UI_TEST_SCENARIO": "confirmation"]
///   app.launch()
///
/// The app then calls `UITestingSupport.blocks(for:)` / `UITestingSupport.machines`
/// instead of hitting CloudKit, so tests run without an iCloud account.
enum UITestingSupport {

    static var isUITesting: Bool {
        CommandLine.arguments.contains("--uitesting")
    }

    static var scenario: String? {
        ProcessInfo.processInfo.environment["UI_TEST_SCENARIO"]
    }

    // MARK: - Responded block tracking
    // Blocks that have been "responded to" are filtered out on subsequent fetches,
    // so the UI reflects the dismissal even when the poll loop re-fetches mock data.
    private static var respondedBlockIDs: Set<String> = []

    static func markResponded(_ blockID: String) {
        respondedBlockIDs.insert(blockID)
    }

    // MARK: - Mock machines

    static var machines: [AskMachine] {
        [AskMachine.mock(id: "mac-1", name: "Kevin's MacBook Pro")]
    }

    // MARK: - Mock blocks by scenario

    // swiftlint:disable function_body_length
    static func blocks(for scenario: String) -> [RKBlock] {
        allBlocks(for: scenario).filter { !respondedBlockIDs.contains($0.id) }
    }

    private static func allBlocks(for scenario: String) -> [RKBlock] {
        switch scenario {

        case "confirmation":
            return [
                tile(scriptID: "claudecode-controller", label: "Claude Code"),
                RKBlock.make(
                    id: "mock-confirmation-1",
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .confirmation,
                    payloadJSON: #"{"title":"Allow Bash?","body":"git status","options":["Allow","Deny"],"urgency":"urgent"}"#,
                    showsInInbox: true
                ),
            ]

        case "confirmation_list":
            return [
                tile(scriptID: "claudecode-controller", label: "Claude Code"),
                RKBlock.make(
                    id: "mock-confirmation-list-1",
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .confirmation,
                    payloadJSON: #"{"title":"Allow Bash?","body":"npm install","options":["Allow","Always allow Bash(npm install)","Deny"],"urgency":"urgent","style":"list"}"#,
                    showsInInbox: true
                ),
            ]

        case "alert":
            return [
                tile(scriptID: "claudecode-controller", label: "Claude Code"),
                RKBlock.make(
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .alert,
                    payloadJSON: #"{"title":"terminal-manager not running","body":"TUI detection is unavailable. Start terminal-manager to enable interactive prompts on iPhone.","urgency":"warning"}"#,
                    showsInInbox: false
                ),
            ]

        case "agent_session":
            return [
                tile(scriptID: "claudecode-controller", label: "1 session"),
                RKBlock.make(
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .agentSession,
                    payloadJSON: #"{"session_id":"sess-abc","project":"ask","is_working":false,"agent_name":"Claude Code"}"#,
                    showsInInbox: false
                ),
            ]

        case "agent_session_working":
            return [
                tile(scriptID: "claudecode-controller", label: "1 session working", statusColor: "blue"),
                RKBlock.make(
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .agentSession,
                    payloadJSON: #"{"session_id":"sess-abc","project":"ask","is_working":true,"agent_name":"Claude Code","current_tool":"Bash","current_preview":"git status"}"#,
                    showsInInbox: false
                ),
            ]

        case "quick_reply":
            return [
                tile(scriptID: "codex-2", label: "Codex"),
                RKBlock.make(
                    machineID: "mac-1",
                    scriptID: "codex-2",
                    blockType: .quickReply,
                    payloadJSON: #"{"title":"Deploy to prod?","description":"Branch: main","options":["Deploy","Cancel"],"urgency":"warning"}"#,
                    showsInInbox: true
                ),
            ]

        case "prompt":
            return [
                tile(scriptID: "claudecode-controller", label: "Claude Code"),
                RKBlock.make(
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .prompt,
                    payloadJSON: #"{"title":"Enter branch name:","placeholder":"feature/...","urgency":"warning"}"#,
                    showsInInbox: true
                ),
            ]

        case "multiple_scripts":
            return [
                tile(scriptID: "claudecode-controller", label: "Claude Code"),
                RKBlock.make(
                    id: "block-1",
                    machineID: "mac-1",
                    scriptID: "claudecode-controller",
                    blockType: .confirmation,
                    payloadJSON: #"{"title":"Allow Read?","body":"~/Documents/notes.txt","options":["Allow","Deny"],"urgency":"urgent"}"#,
                    showsInInbox: true
                ),
                tile(scriptID: "codex-2", label: "Codex"),
                RKBlock.make(
                    id: "block-2",
                    machineID: "mac-1",
                    scriptID: "codex-2",
                    blockType: .confirmation,
                    payloadJSON: #"{"title":"Allow Bash?","body":"npm test","options":["Allow","Deny"],"urgency":"warning"}"#,
                    showsInInbox: true
                ),
            ]

        case "empty":
            return []

        default:
            return []
        }
    }
    // swiftlint:enable function_body_length

    // MARK: - Helpers

    private static func tile(scriptID: String, label: String, statusColor: String = "gray") -> RKBlock {
        RKBlock.make(
            machineID: "mac-1",
            scriptID: scriptID,
            blockType: .tile,
            payloadJSON: #"{"label":"\#(label)","status_color":"\#(statusColor)","action_required":false}"#
        )
    }
}

// MARK: - RKBlock mock factory

extension RKBlock {
    static func make(
        id: String = UUID().uuidString,
        machineID: String = "machine-1",
        scriptID: String = "test-script",
        blockType: RKBlockType,
        payloadJSON: String = "{}",
        showsInInbox: Bool = false,
        createdAt: Date = Date()
    ) -> RKBlock {
        RKBlock(
            id: id,
            machineID: machineID,
            scriptID: scriptID,
            scriptName: nil,
            scriptIcon: nil,
            scriptIconData: nil,
            scriptIconSVG: nil,
            blockType: blockType,
            payloadJSON: payloadJSON,
            createdAt: createdAt,
            expiresAt: nil,
            scriptType: "tile",
            showsInInbox: showsInInbox
        )
    }
}

// MARK: - AskMachine mock factory

extension AskMachine {
    /// Direct memberwise init for use in test/mock contexts.
    /// `AskMachine`'s only body-level init is the failable `init?(record:)`, so we
    /// provide this unfailable convenience init in an extension.
    init(id: String, name: String, lastHeartbeat: Date, status: MachineStatus, activeJobID: String?) {
        self.id = id
        self.name = name
        self.lastHeartbeat = lastHeartbeat
        self.status = status
        self.activeJobID = activeJobID
    }

    static func mock(id: String, name: String, status: MachineStatus = .idle) -> AskMachine {
        AskMachine(
            id: id,
            name: name,
            lastHeartbeat: Date(),
            status: status,
            activeJobID: nil
        )
    }
}
