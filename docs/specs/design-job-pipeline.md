# Design: Job Pipeline

## Overview

Wire up the job execution pipeline end-to-end: agent configuration on Mac, `JobExecutor` service that polls and runs jobs, output streaming via `OutputChunk` records, and iOS UI for submitting jobs and watching them run.

Also fixes the path traversal vulnerability in `ScriptManager` (security review item #1).

---

## Architecture

### Two execution models (both coexist)

| Model | What | How |
|---|---|---|
| **Scripts** | Long-running MCP daemons | Emit/clear blocks; ScriptManager manages lifecycle |
| **Agents/Jobs** | One-shot on-demand executors | Launched per job; prompt as `$1`; output streamed back |

Scripts and agents can share the same vault directory but are configured separately.

---

## Mac Companion

### AgentManager (new service)

`@Observable final class AgentManager`

- Holds `private(set) var agents: [AgentRecord]`
- On init: fetches all agents for this `machineID` from CloudKit
- `add(_ agent: AgentRecord)` → `cloudKit.saveAgent`, appends locally
- `update(_ agent: AgentRecord)` → `cloudKit.saveAgent`, replaces locally
- `delete(agentID: String)` → `cloudKit.deleteAgent`, removes locally

### JobExecutor (new service)

`final class JobExecutor: @unchecked Sendable`

Polling loop (5s interval) via `Task.sleep`. One job at a time enforced by `isExecuting: Bool`.

**Per-job flow:**
1. `fetchQueuedJobs` → take oldest
2. Look up agent in `AgentManager`; validate script is within vault (`resolvingSymlinksInPath` check)
3. If invalid: `updateJob(status: .failed)`; continue polling
4. `updateJob(status: .acknowledged)`
5. `saveMachine(status: .busy, activeJobID: jobID)`
6. Build `Process`: executableURL from agent script path, arguments `[prompt]`, env from Keychain keys, cwd = vault root, stdin = `/dev/null`
7. `updateJob(status: .running, startedAt: now)`
8. Launch. Start two background tasks:
   - **Output task**: reads stdout line-by-line, batches into `OutputChunk` writes every 500ms
   - **Cancellation task**: polls `fetchJobStatus` every 2s; if `cancelled`, kills process
9. Timeout: `DispatchQueue.asyncAfter` kills process after `capabilities.timeout` seconds
10. On termination: flush remaining output, determine final status (exit 0 → `.completed`, else `.failed`; if cancelled → `.cancelled`)
11. `updateJob(status: final, completedAt: now, exitCode: code)`
12. `saveMachine(status: .idle, activeJobID: nil)`
13. `actionHistory.record(jobID, agentName, prompt, status, duration, exitCode)`
14. Resume polling

**Output batching:**
- Accumulate text in a `String` buffer
- Every 500ms (or on process exit), if buffer non-empty: write `OutputChunkRecord`, increment sequence counter, clear buffer
- `OutputChunkRecord.recordName` = `"\(jobID)-\(sequence08d)"` for deterministic ordering

**Keychain env injection:**
```swift
SecItemCopyMatching([
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: key,
    kSecReturnData: true
] as CFDictionary, &result)
```
Silently skips keys not found in Keychain.

### CloudKitService additions

- `fetchAgents(machineID:) -> [AgentRecord]` — query by machineID
- `fetchJobStatus(jobID:) -> JobStatus?` — fetch single record, return status field (for cancellation check)

### purgeOldRecords fix

Remove `job` from the always-purge list. Job records are needed for iOS history. They'll be cleaned up by a separate 7-day TTL strategy in a future pass.

### ScriptManager path traversal fix

In `launch(manifest:scriptDir:)` and icon loading, after `appendingPathComponent`:
```swift
let resolved = entryURL.resolvingSymlinksInPath()
guard resolved.path.hasPrefix(scriptDir.resolvingSymlinksInPath().path + "/")
      || resolved.path == scriptDir.resolvingSymlinksInPath().path
else {
    print("[ScriptManager] Path traversal rejected: \(entryURL.path)")
    return
}
```
Same check applied to `iconURL`.

### SettingsView — Agents section

New section in `ActionsSettingsTab` below Scripts:

```
Section("Agents") {
    ForEach(agents) { AgentRowView }
    Button("Add Agent…") → AddEditAgentSheet
}
```

`AddEditAgentSheet` (sheet, not navigation): Form with:
- Name (TextField)
- Script (file picker scoped to vault, shows relative path)
- Timeout (Stepper, 10–3600s, default 60)
- Network toggle
- Subprocess toggle
- Read Paths (list + add/remove)
- Write Paths (list + add/remove)
- Env Keys (list + add/remove)

### AskMacApp wiring

```swift
let am = AgentManager(cloudKit: ck, machineID: s.machineID)
let je = JobExecutor(cloudKit: ck, agentManager: am, actionHistory: ah, machineID: s.machineID, settings: s)
// In task: je.start()
// In SettingsView: .environment(agentManager)
```

---

## iOS App

### iOSCloudKitService additions

```swift
func fetchOutputChunks(jobID: String) async throws -> [AskOutputChunk]
```
Query `OutputChunk` by `jobID`, sort by `sequence` ascending, return all.

### MachineDetailView (expanded)

New state:
- `agents: [AskAgent]`
- `jobs: [AskJob]`

On `.task`: fetch both in parallel.

New sections in List:
- **Actions** (if agents non-empty): `NavigationLink` per agent → `NewJobView`
- **Recent Jobs** (if jobs non-empty): `NavigationLink` per job → `JobDetailView`; each row shows prompt (1 line truncated), agent name, status icon + color, relative time

### NewJobView (new file)

```swift
struct NewJobView: View {
    let agent: AskAgent
    let machine: AskMachine
```

- Capability summary chips (network, subprocess, paths)
- Machine status indicator
- `TextField("Prompt", text: $prompt, axis: .vertical)`
- Send button: `cloudKit.createJob(machineID:agentID:prompt:)` → navigate to `JobDetailView(job:)`
- `@State private var job: AskJob?` — set after successful create; drives navigation

### JobDetailView (new file)

```swift
struct JobDetailView: View {
    let initialJob: AskJob
```

State:
- `job: AskJob` (refreshed while non-terminal)
- `chunks: [AskOutputChunk]` (accumulated)
- `pollTask: Task?`
- `autoScroll: Bool = true`

Polling: every 2s while `!job.status.isTerminal`:
1. `fetchJob(jobID:)` → update `job`
2. `fetchOutputChunks(jobID:)` → replace `chunks` (sorted by sequence)

Layout:
- Status header (icon + label + color)
- Agent name, machine name, timestamps
- Monospaced ScrollView with output text
  - Auto-scrolls to bottom unless user scrolled up
- Cancel button (shown while non-terminal): `cloudKit.cancelJob` → optimistic status update

---

## File Checklist

**New (Mac):**
- `AskMac/Sources/AskMac/Services/AgentManager.swift`
- `AskMac/Sources/AskMac/Services/JobExecutor.swift`

**Modified (Mac):**
- `CloudKitService.swift` — `fetchAgents`, `fetchJobStatus`, fix `purgeOldRecords`
- `ScriptManager.swift` — path traversal fix
- `SettingsView.swift` — Agents section + AddEditAgentSheet
- `AskMacApp.swift` — wire AgentManager + JobExecutor

**New (iOS):**
- `ask/ask/NewJobView.swift`
- `ask/ask/JobDetailView.swift`

**Modified (iOS):**
- `iOSCloudKitService.swift` — `fetchOutputChunks`
- `MachineDetailView.swift` — agents + job history
