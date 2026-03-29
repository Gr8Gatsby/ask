# Ask — Functional Specification

## Overview

Ask is a mobile application that lets a user send prompts and commands to AI agents and CLI tools running on one or more personal Macs, monitor their execution in real time, and review results — all from an iPhone. A companion Mac app runs quietly in the background, receives tasks, executes them using whatever tools are configured on that machine, and streams output back to the phone.

The system is provider-agnostic. It does not assume Claude, OpenAI, or any specific tool. Each Mac can have any number of named agents configured, each pointing to any command the user wants to run.

---

## Users and Devices

- **One user** — the app owner. No multi-user or sharing model in v1.
- **One or more personal Macs** — each runs the Mac companion app.
- **One iPhone** — runs the iOS app.
- The user's iCloud account ties both apps together.

---

## Core Concepts

### Machine
A registered Mac that has the companion app installed. Each machine has:
- A user-assigned name (e.g., "Mac Mini", "MacBook Pro")
- A status reflecting whether it is reachable and what it is doing
- A list of agents configured on it
- A history of jobs it has run

### Agent
A named, capability-declared executor registered in the Mac companion app. Each agent has:
- A name (e.g., "Claude Code", "GPT Script", "Build Runner")
- A registered script — a file located within the machine's Scripts Vault that is executed when a job is sent
- A declared set of capabilities that define exactly what the script is permitted to do at runtime
- An optional icon for display purposes

Agents are configured entirely within the Mac companion app. The iOS app discovers them and displays their declared capabilities automatically.

### Scripts Vault
A designated directory on the Mac (chosen by the user during Mac companion setup) that is the only source of executable scripts. No script outside the vault can be registered as an agent. This is the primary security boundary for execution on the Mac.

### Capability Declaration
Every agent must declare its capabilities before it can be used. All capabilities are denied by default. A capability must be explicitly enabled to be available to the script at runtime.

The declarable capabilities are:

| Capability | Default | Description |
|---|---|---|
| `read` | denied | One or more directory paths the script may read from |
| `write` | denied | One or more directory paths the script may write to |
| `network` | denied | Outbound network access (required for agents that call external APIs) |
| `subprocess` | denied | Permission to spawn child processes (required for agents that invoke other CLI tools) |
| `timeout` | 60 seconds | Maximum runtime; the process is killed if exceeded |
| `env` | empty | Named Keychain items to inject as environment variables at runtime |

The declared capabilities are enforced at launch time and visible to the user on both the Mac companion and iOS app before any job is sent.

### Job
A unit of work sent from the iOS app to a specific agent on a specific machine. Each job has:
- The prompt or input text the user sent
- The agent it was directed to
- The machine it ran on
- A status tracking its lifecycle
- All output produced during execution
- Timestamps for when it was created, started, and finished

### Output
The text output (stdout and stderr) produced by a running job. Output streams back to the iOS app in near-real time as the agent produces it.

---

## Machine States

| State | Meaning |
|---|---|
| **Online** | The companion app is running and recently reported in. No active job. |
| **Busy** | The companion app is running and currently executing a job. |
| **Sleeping** | The Mac has not reported in recently but was previously active. May resume. |
| **Offline** | The Mac has not reported in for an extended period. Jobs sent will queue. |
| **Unregistered** | The machine record exists but the companion app has never connected. |

The iOS app computes the machine's state from how recently the companion app reported in and whether a job is active. It does not require the Mac to be reachable to determine this.

---

## Job Lifecycle

```
Queued → Acknowledged → Running → Completed
                                → Failed
                    → Cancelled (user action)
```

| Status | Meaning |
|---|---|
| **Queued** | Job created by iOS app, waiting for Mac to pick it up |
| **Acknowledged** | Mac companion has received the job and is about to start |
| **Running** | Command is executing; output is streaming |
| **Completed** | Command finished successfully |
| **Failed** | Command exited with an error |
| **Cancelled** | User cancelled before or during execution |

If the Mac is offline when a job is sent, the job remains `Queued` until the Mac comes back online, at which point it is picked up automatically.

---

## iOS App — Functional Requirements

### Machine List (Home Screen)
- Displays all registered machines in a list
- Each entry shows: machine name, current status (with visual indicator), and how long ago it last reported in
- Status updates automatically without requiring a manual refresh
- Tapping a machine navigates to its detail screen
- A button to register a new machine is always accessible
- If no machines are registered, the screen shows an empty state with instructions to install the Mac companion

### Machine Detail Screen
- Shows the machine name and current status at the top
- Lists all agents configured on that machine
- Shows a history of recent jobs run on that machine, sorted by most recent first
- Each job in the history shows: the prompt (truncated), agent name, status, and time
- Tapping an agent navigates to a screen to send a new job to that agent
- Tapping a job in the history navigates to the job detail screen
- If the machine is offline, the user can still browse history and send jobs (they will queue)

### Agent Detail Screen
- Shows the agent name and which machine it belongs to
- Displays the agent's declared capabilities as a visual summary (e.g., "Network · Read ~/code/myproject · Subprocess")
- Read and write paths are shown explicitly so the user knows what filesystem access will be granted
- Provides a button to send a new job to this agent

### New Job Screen
- Shows the agent name, machine, and a compact capability summary
- A text input for the prompt
- A send button that creates the job and navigates immediately to the job detail screen
- The user can see at a glance whether the machine is online or offline before sending

### Job Detail Screen
- Shows the job's current status prominently
- Shows the agent name, machine name, and when the job was created
- Displays all output received so far in a scrolling terminal-style view
- New output appends automatically in near-real time as it arrives from the Mac
- The output view scrolls to the bottom automatically as new content arrives, but stops auto-scrolling if the user scrolls up to review earlier output
- A cancel button is visible while the job is in `Queued`, `Acknowledged`, or `Running` state
- When the job completes or fails, the final status and exit information are shown
- Output is readable in both light and dark mode
- Output is selectable/copyable

### Add Machine Screen
- Provides instructions for installing the Mac companion app
- Shows a camera viewfinder for scanning a QR code
- The QR code is displayed by the Mac companion app during its initial setup
- After scanning, the machine appears immediately in the machine list
- If the camera is unavailable, offers a manual entry field for a pairing code shown in the Mac companion

### Job History (Global)
- Accessible from the home screen
- Shows all jobs across all machines, sorted by most recent
- Filterable by machine, agent, and status
- Tapping any job navigates to its job detail screen

### Search
- A search field on the home screen filters machines by name
- Search on the job history screen filters by prompt text, agent name, or machine name

### Notifications
- The app requests notification permission on first launch
- When a job completes or fails, a local notification is delivered if the app is in the background
- Tapping the notification navigates directly to the job detail screen

### Settings
- Ability to rename a registered machine
- Ability to remove a registered machine (with confirmation)
- No other settings in v1

---

## Mac Companion App — Functional Requirements

### General Behavior
- Runs as a menu bar application with no Dock icon
- Starts automatically on login
- Always running in the background while the Mac is on
- When the Mac wakes from sleep, immediately checks for queued jobs

### Menu Bar Icon
- Reflects current status: idle, busy (with job count), or disconnected (cloud sync issue)
- Clicking the icon opens a popover with current status, active job progress (if any), and access to settings

### Machine Registration and Pairing
- On first launch, the Mac companion generates a permanent unique identifier for this machine and an Ed25519 cryptographic keypair stored in the macOS Keychain
- Prompts the user to enter a display name for this machine
- Prompts the user to select a Scripts Vault directory (the only location from which scripts may be registered as agents)
- Displays a QR code and a text pairing code encoding the machine's identity and public key
- The iOS app scans the code, completing the pairing: both sides exchange and store each other's public keys
- Each Mac is paired with exactly one iPhone. Re-pairing revokes and replaces the previously trusted device.
- The machine becomes visible in the iOS app only after successful cryptographic pairing

### Heartbeat
- While the companion app is running, it reports its status to the shared data store at regular intervals (every 30 seconds)
- When a job starts, status updates to busy; when the job ends, status returns to idle

### Scripts Vault
- During setup, the user selects a directory on the Mac to serve as the Scripts Vault
- Only scripts physically located within the vault can be registered as agents
- The vault path is displayed in settings and can be changed (changing it invalidates all agents pointing to scripts outside the new path)
- The vault directory is not created or managed by the app — the user is responsible for placing scripts there

### Agent Configuration
- A settings screen lists all configured agents for this machine
- The user can add, edit, and delete agents
- Adding an agent requires:
  - A name
  - Selecting a script from within the Scripts Vault (file picker scoped to the vault directory)
  - Declaring capabilities: read paths, write paths, network, subprocess, timeout
  - Optionally referencing named Keychain items to inject as environment variables
- The prompt is passed to the script as its first argument (`$1`). The script is responsible for using it.
- No shell interpolation of the prompt occurs — it is passed directly as a process argument
- A test button runs the agent with a sample prompt (`"test"`) and shows live output in a preview pane, confirming the configuration works before it is used from iOS
- Agents that fail the test can still be saved but are shown with a warning indicator

### Job Execution
- The companion app monitors for new jobs assigned to this machine
- Before executing a job, the companion verifies the job's signature against the paired iPhone's stored public key. Jobs that fail signature verification are rejected and marked `Failed` with a security error — they are never executed.
- When a job arrives (machine is online) or when the Mac wakes (machine was offline), the companion picks up any `Queued` jobs in order of creation time
- Before executing, the companion verifies:
  - The job is signed by the paired iOS device
  - The target agent still exists and its script is still within the vault
  - The declared capability paths exist on the filesystem
- The companion updates the job status to `Acknowledged`, then `Running`
- The script is launched as a child process with:
  - The prompt passed as the first argument (`$1`)
  - Only the declared environment variables injected (sourced from Keychain at runtime)
  - No inheritance of the companion app's shell environment
  - Working directory set to the vault root (scripts run relative to the vault unless read/write paths are declared)
- Standard output and standard error are both captured separately
- Output is written back to the shared data store in chunks as it is produced, enabling near-real-time streaming to the iOS app
- The process is killed if it exceeds the agent's declared timeout
- When the process exits, the companion updates the job to `Completed` (exit code 0) or `Failed` (non-zero exit code), and records the exit code
- One job runs at a time per machine. Additional queued jobs wait until the current job finishes.

### Cancellation
- When the user cancels a job from iOS, the job's status is set to `Cancelled` in the shared data store
- The companion app checks for cancellation periodically during execution and terminates the process if detected

### Error Handling
- If the working directory does not exist at execution time, the job fails immediately with a clear error message in the output
- If the command template produces an invalid command, the job fails with the shell error output
- If the companion loses connectivity to the shared data store, it continues executing any in-progress job and retries syncing

---

## Security Model

### Principles
- **Deny by default.** No script can run, no filesystem path can be accessed, and no environment variable is visible to a script unless explicitly declared.
- **Explicit registration required.** Only scripts located within the designated Scripts Vault and explicitly registered in the Mac companion app can be invoked. There is no way to run an arbitrary command from the iOS app.
- **Cryptographic trust.** Every job is signed by the iOS app's private key. The Mac companion verifies the signature before executing anything. Compromising the CloudKit data store alone is not sufficient to execute commands on a Mac.
- **One paired device.** Each Mac trusts exactly one iPhone. There is no ambient trust for "anyone on the same iCloud account."
- **No shell interpolation.** The user's prompt is passed as a process argument, never interpolated into a shell string. This eliminates a class of prompt injection attacks.
- **Environment isolation.** Scripts receive only the environment variables explicitly declared in their capability configuration, sourced from the macOS Keychain. The shell environment of the companion app is never inherited.

### Cryptographic Pairing

**Key generation:**
- The Mac companion generates an Ed25519 keypair on first launch. The private key is stored in the macOS Keychain and never leaves the machine.
- The iOS app generates an Ed25519 keypair on first launch. The private key is stored in the iOS Keychain.

**Pairing flow:**
1. Mac companion encodes its public key and machine ID into a QR code
2. iOS app scans the QR code and stores the Mac's public key, associated with that machine
3. iOS app sends its own public key to the Mac via the shared data store (encrypted channel — CloudKit private database)
4. Mac companion stores the iOS public key; pairing is complete
5. All subsequent jobs are signed by the iOS private key and verified by the Mac using the stored iOS public key

**Re-pairing:**
- The Mac companion settings include a "Revoke and Re-pair" option
- This generates a new Mac keypair, invalidates the stored iOS public key, and presents a new QR code
- The previously paired iPhone loses the ability to send jobs until it re-pairs

### Execution Sandbox

**What is enforced at runtime:**
- Script must be located within the registered Scripts Vault directory (path verified before launch)
- Process is launched with an explicit argument array — no shell, no interpolation
- Only declared Keychain-referenced environment variables are injected; all other env vars are absent
- Process is killed after the declared timeout
- No working directory other than the vault root is set unless read/write paths are declared (scripts are expected to use declared paths explicitly)

**What is not OS-enforced in v1 (declared intent, not hard technical barrier):**
- Filesystem access restrictions beyond the vault boundary are not enforced via macOS sandbox profiles on child processes. A script could technically access paths outside its declared `read`/`write` paths. The declared capabilities serve as the user's explicit authorization record and are shown in the iOS app.
- Network access is not blocked at the OS level for scripts that do not declare `network: true`. The declaration is an explicit authorization signal, not a firewall rule.
- OS-level sandbox profiles per child process is a planned v2 hardening feature.

### Threat Model

| Threat | Mitigation |
|---|---|
| Attacker gains access to iCloud account | Jobs still require a valid iOS private key signature. CloudKit data alone cannot execute anything. |
| Malicious QR code scanned during pairing | Pairing screen shows decoded machine name and ID before confirmation. User must explicitly confirm. |
| Prompt injection (`; rm -rf ~` in prompt text) | Prompt is passed as a single process argument, never via a shell. Shell metacharacters have no effect. |
| Registered script escapes declared paths | v1: declared paths are shown to user as explicit authorization. v2: OS sandbox enforcement. |
| Unauthorized agent invocation | Only agents registered on the Mac can be invoked. The iOS app cannot reference a script by path. |
| Compromised Mac companion binary | Outside scope — assumes the companion app binary is trusted (notarized by developer). |

---

## Communication and Data Sync

### Design Goals
- Jobs created on iOS must persist even when the Mac is offline
- The iOS app must receive output updates without polling
- Multiple machines must coexist without interfering with each other
- No third-party server or infrastructure is required

### Behavior Requirements
- A job created while the target Mac is offline must be delivered and executed when that Mac next comes online, with no user action required
- Output from a running job must appear on the iOS app within a few seconds of being produced on the Mac
- Machine status on the iOS app must reflect reality within 60–90 seconds of the Mac going offline or coming back online
- All data is tied to the user's personal iCloud account

---

## Claude Code Supervision

### Overview

The app can supervise any Claude Code session running on a paired Mac — whether launched from the terminal or from the Mac companion app. When Claude Code needs permission to run a tool, the user receives a prompt on iPhone and can approve or deny it without touching the Mac.

Claude Code sessions appear as first-class items in the iOS app, grouped like conversation threads. Each session corresponds to one Claude Code invocation. No script names or filesystem paths are shown — the UI surfaces what Claude wants to do (e.g., "Allow Bash?"), not how it is implemented.

### Session States

| State | Meaning |
|---|---|
| **Waiting** | Claude is paused, waiting for the user to respond to a permission request |
| **Active** | Claude is running; no pending requests |
| **Completed** | Session has ended |

### iOS — Claude Sessions Screen

- The Machine Detail screen shows a "Claude Sessions" section above all other content when any sessions exist for that machine
- Each session row shows: a status dot (orange = waiting, green = active), the session title (what Claude is requesting), and how long ago it was last active
- Sessions with pending requests are sorted to the top; within each group, sorted by most recent activity
- Tapping a session navigates to the Session Detail screen
- The screen refreshes automatically: every 5 seconds while visible, immediately when the app foregrounds, and immediately after the user responds to a request

### iOS — Session Detail Screen

- Shows all pending permission requests for the session
- Each request shows the tool name (title) and a preview of what it wants to do (body text)
- Below the description, the dynamic response options are shown as buttons (e.g., Allow / Always allow Bash(git *) / Deny)
- When no requests are pending, shows an empty state: "Claude is running. You'll be notified when input is needed."
- After the user responds to the last pending request, the screen dismisses automatically and the session list refreshes

### Mac — Hook Integration

- A `PermissionRequest` hook in `~/.claude/settings.json` fires whenever Claude Code needs tool authorization
- The hook script reads the structured JSON payload (tool name, tool input, session ID, permission suggestions) from stdin
- It extracts a human-readable preview of what Claude wants to do (command, file path, query, etc.)
- It builds a dynamic option list from `permission_suggestions` in the payload — these are Claude Code's own contextual suggestions (e.g., "Always allow Bash(git status)")
- The prompt is sent to the iPhone via the event pipeline; the hook blocks until the user responds (5-minute timeout → auto-deny)
- Response mapping:
  - **Allow**: hook exits 0, Claude proceeds
  - **Always allow X**: hook outputs `updatedPermissions` referencing the suggestion — Claude Code natively records the rule; hook exits 0
  - **Deny**: hook outputs deny decision with message; Claude sees an error; hook exits 2
  - **Timeout**: hook exits 2 (safe default — deny)

### Event Pipeline

```
Claude Code needs tool authorization
    ↓ PermissionRequest hook fires
~/.ask/scripts/ask-permission.sh reads JSON from stdin
    ↓ extracts preview, builds options from permission_suggestions
~/.ask/scripts/ask-prompt.sh --session-id SESSION --body PREVIEW TITLE [options...]
    ↓ writes ~/.ask/incoming/{eventID}.json (atomically)
LocalEventService (Mac companion) picks up file
    ↓ upserts AskSession (status: waiting) + saves AskEvent (linked to session)
CloudKit push → iPhone notified
    ↓ user taps Allow
iOSCloudKitService.saveResponse() → AskResponse record in CloudKit
    ↓ ResponseWatcherService (Mac) picks up response → writes ~/.ask/responses/{eventID}.json
ask-prompt.sh unblocks → ask-permission.sh outputs allow decision → Claude proceeds
    ↓
AskSession status updated to "active"; iOS view dismisses; session list refreshes
```

---

## Constraints and Scope (v1)

- Single iCloud account — no sharing between users
- One job runs at a time per machine — no parallel execution
- Jobs are not editable after creation
- No job scheduling or recurring jobs
- No file attachments — prompts are plain text only
- No voice input in v1
- Broadcast to multiple machines simultaneously is not supported; jobs are always sent to a specific machine/agent
- The Mac companion runs on macOS only; no iOS/iPadOS companion

---

## Change Log

| Date | Change |
|---|---|
| 2026-03-28 | Initial spec created |
| 2026-03-28 | Added security model: cryptographic pairing, Scripts Vault, capability declarations, threat model |
| 2026-03-28 | Mac companion service layer v1: CloudKit schema, HeartbeatService, JobWatcher, JobExecutor, minimal menu bar UI |
| 2026-03-29 | Claude Code supervision: PermissionRequest hook, AskSession record type, Sessions UI in iOS (MachineDetailView + SessionDetailView), dynamic options from permission_suggestions, real-time refresh pipeline |
| 2026-03-29 | UI: renamed "Agents" → "Actions" in all labels (no schema change) |
| 2026-03-29 | Action History: local JSONL log, History window in Mac companion (Dashboard + Log tabs), stale event auto-cleanup (6-min TTL for hook-based events) |
| 2026-03-29 | Flatten iOS navigation: HomeView surfaces sessions + actions + machine status directly; gear button opens SettingsSheetView with machine drill-down |
