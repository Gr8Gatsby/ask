import Foundation

/// A session unified across local on-disk registries and remote CloudKit
/// task records. The dedup key is `sessionID`, which equals `task_id` in
/// the daemon's local registry and `AskTaskRecord.taskID` in CloudKit.
struct UnifiedSession: Identifiable, Hashable, Sendable {
    enum Origin: Sendable { case local, remote }
    enum Health: String, Sendable { case healthy, warning, errored, stalled }

    let sessionID: String
    let origin: Origin
    let machineID: String
    let machineName: String
    let scriptID: String
    let scriptName: String
    let scriptVersion: String?
    let title: String?
    let lastMessage: String?
    let currentPreview: String?
    let currentTool: String?
    let state: String?
    let lastActivityAt: Date
    let health: Health

    var id: String { sessionID }
    var isLocal: Bool { origin == .local }
}

extension UnifiedSession {
    /// Default active-window threshold. Sessions whose `lastActivityAt`
    /// is older than this are excluded from the active list.
    static let activeWindow: TimeInterval = 10 * 60

    /// Threshold inside the active window after which a session flips
    /// from `healthy` to `stalled`.
    static let stalledThreshold: TimeInterval = 2 * 60

    /// Daemon states that mean "this session is no longer live" — used
    /// to drop entries from the active list even if their lastActivity
    /// is recent.
    static let terminalStates: Set<String> = ["stopped", "errored_terminal"]
}

// MARK: - Local registry decoding

/// Parsed shape of one entry in `~/.ask/<daemon>-sessions.json`. Only
/// fields the UI cares about; extras are ignored.
struct LocalSessionEntry: Sendable {
    let sessionID: String
    let scriptID: String        // "claude-3", "codex-3", ...
    let state: String?
    let currentTool: String?
    let preview: String?
    let lastMessage: String?
    let lastPrompt: String?
    let lastSeen: Date
    let isTransient: Bool
    let pendingPermissionTitle: String?

    init?(scriptID: String, raw: [String: Any]) {
        guard let sid = raw["session_id"] as? String else { return nil }
        // last_seen is a unix timestamp (float seconds since epoch).
        let lastSeenEpoch = (raw["last_seen"] as? Double) ?? 0
        self.sessionID = sid
        self.scriptID = scriptID
        self.state = raw["state"] as? String
        self.currentTool = (raw["current_tool"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.preview = (raw["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.lastMessage = (raw["last_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.lastPrompt = (raw["last_prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.lastSeen = Date(timeIntervalSince1970: lastSeenEpoch)
        self.isTransient = (raw["is_transient"] as? Bool) ?? false
        let pending = raw["pending_permission"] as? [String: Any]
        self.pendingPermissionTitle = pending?["title"] as? String
    }
}

// MARK: - Health classification

extension UnifiedSession.Health {
    /// Computes the health badge for a session given its current state.
    /// `lastActivityAt` is in the same reference frame as `now`.
    static func classify(
        state: String?,
        pendingPermissionTitle: String?,
        isTransient: Bool,
        lastActivityAt: Date,
        now: Date
    ) -> UnifiedSession.Health {
        if state == "errored" { return .errored }

        let age = now.timeIntervalSince(lastActivityAt)
        if age >= UnifiedSession.stalledThreshold { return .stalled }

        if pendingPermissionTitle != nil { return .warning }
        if isTransient && (state ?? "") == "idle" { return .warning }

        return .healthy
    }
}

// MARK: - Merge

extension UnifiedSession {
    /// Builds a unified session from a local entry. The caller supplies
    /// machine identity and script version because those live outside
    /// the JSON registry.
    static func fromLocal(
        _ entry: LocalSessionEntry,
        machineID: String,
        machineName: String,
        scriptName: String,
        scriptVersion: String?,
        now: Date = Date()
    ) -> UnifiedSession {
        UnifiedSession(
            sessionID: entry.sessionID,
            origin: .local,
            machineID: machineID,
            machineName: machineName,
            scriptID: entry.scriptID,
            scriptName: scriptName,
            scriptVersion: scriptVersion,
            title: entry.lastPrompt?.isEmpty == false ? entry.lastPrompt : nil,
            lastMessage: entry.lastMessage,
            currentPreview: entry.preview,
            currentTool: entry.currentTool,
            state: entry.state,
            lastActivityAt: entry.lastSeen,
            health: Health.classify(
                state: entry.state,
                pendingPermissionTitle: entry.pendingPermissionTitle,
                isTransient: entry.isTransient,
                lastActivityAt: entry.lastSeen,
                now: now
            )
        )
    }

    /// Builds a unified session from a CloudKit `AskTaskRecord`. The
    /// caller supplies the machine display name (resolved from the
    /// Machine record set), defaulting to the machineID string.
    static func fromRemote(
        _ task: AskTaskRecord,
        machineName: String,
        now: Date = Date()
    ) -> UnifiedSession {
        let state = task.status  // "working", "completed", ...
        let isCompleted = state == "completed"
        return UnifiedSession(
            sessionID: task.taskID,
            origin: .remote,
            machineID: task.machineID,
            machineName: machineName,
            scriptID: task.scriptID,
            scriptName: task.scriptName,
            scriptVersion: nil,
            title: task.title.isEmpty ? nil : task.title,
            lastMessage: nil,
            currentPreview: nil,
            currentTool: nil,
            state: state,
            lastActivityAt: task.lastActivityAt,
            health: isCompleted
                ? .stalled
                : Health.classify(
                    state: state,
                    pendingPermissionTitle: nil,
                    isTransient: false,
                    lastActivityAt: task.lastActivityAt,
                    now: now
                )
        )
    }

    /// Merges `remote` into `local`, preferring local fields where both
    /// have a value (since local registries carry richer state).
    static func merge(local: UnifiedSession, remote: UnifiedSession) -> UnifiedSession {
        UnifiedSession(
            sessionID: local.sessionID,
            origin: .local,
            machineID: local.machineID,
            machineName: local.machineName,
            scriptID: local.scriptID,
            scriptName: local.scriptName,
            scriptVersion: local.scriptVersion ?? remote.scriptVersion,
            title: local.title ?? remote.title,
            lastMessage: local.lastMessage ?? remote.lastMessage,
            currentPreview: local.currentPreview ?? remote.currentPreview,
            currentTool: local.currentTool ?? remote.currentTool,
            state: local.state ?? remote.state,
            lastActivityAt: max(local.lastActivityAt, remote.lastActivityAt),
            health: local.health
        )
    }
}

// MARK: - Active filter

extension UnifiedSession {
    /// True if the session should appear in the active list given the
    /// reference time `now`.
    ///
    /// Trust the daemon's view: if a session is still in the registry and
    /// not in a terminal state, treat it as active. The daemon already GCs
    /// genuinely-dead sessions after its own idle threshold (10 min for
    /// no-routing zombies, faster for tty/tmux liveness probes); we don't
    /// need a separate `lastActivityAt` window here.
    ///
    /// The previous policy required `lastActivityAt` within 10 min, which
    /// wrongly hid a long-running session whose last hook event predated
    /// the window — exactly the case the user reported when a busy
    /// `running_tool` session was shown by the local registry view but
    /// missing from the unified view.
    ///
    /// `now` is kept on the signature for future policy that may bring
    /// back a soft threshold for visual de-emphasis (vs. exclusion).
    func isActive(now: Date = Date()) -> Bool {
        _ = now
        if let s = state, UnifiedSession.terminalStates.contains(s) { return false }
        return true
    }
}
