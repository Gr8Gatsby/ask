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
- Accessible from the iOS settings sheet (gear button on home screen)
- Shows the machine name and current status
- Lists all agents configured on that machine; each row shows name, icon, and a compact capability summary
- Tapping an agent navigates to a New Job screen for that agent
- Shows a history of recent jobs run on that machine, sorted by most recent first
- Each job row shows: the prompt (truncated), agent name, status indicator, and relative time
- Tapping a job row navigates to the Job Detail screen
- If the machine is offline, the user can still browse history and send jobs (they will queue)

### New Job Screen
- Shows the agent name and a full capability summary
- A text input for the prompt
- Displays whether the target machine is online or offline
- A send button that creates the job and navigates immediately to the Job Detail screen

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

### Connected Devices
- The Mac companion displays which iPhones have recently connected in the menu bar popover, between the status row and the scripts list
- Each connected device shows the device name and how long ago it was last seen
- Only devices seen within the last hour are shown; older records are hidden but not deleted
- The user can revoke a specific device with confirmation; revoking blocks that device and deletes its presence record from CloudKit
- Blocked devices are ignored on future check-ins — their heartbeat records are deleted automatically by the Mac when detected
- Blocked devices are managed in Settings > General > Blocked Devices; any blocked device can be unblocked from there
- The iOS app writes a device presence record (device ID, device name, last seen) to CloudKit for each known Mac at most every 30 minutes; the device ID is stable per app install

### Scripts Vault
- During setup, the user selects a directory on the Mac to serve as the Scripts Vault
- Only scripts physically located within the vault can be registered as agents
- The vault path is displayed in settings and can be changed (changing it invalidates all agents pointing to scripts outside the new path)
- The vault directory is not created or managed by the app — the user is responsible for placing scripts there

### Agent Configuration
- Settings > Actions tab has an "Agents" section, separate from the Scripts section
- The user can add, edit, and delete agents
- Adding an agent requires:
  - A name
  - Selecting a script from within the Scripts Vault (file picker scoped to the vault directory)
  - Declaring capabilities: read paths, write paths, network, subprocess, timeout
  - Optionally referencing named Keychain items to inject as environment variables
- The prompt is passed to the script as its first argument (`$1`). The script is responsible for using it.
- No shell interpolation of the prompt occurs — it is passed directly as a process argument
- Agents are published to CloudKit so the iOS app can discover and invoke them
- An agent's script must be located within the registered Scripts Vault

### Job Execution
- A background service polls CloudKit for jobs assigned to this machine with status `Queued`
- When a queued job is found, the companion verifies the target agent exists and its script is within the vault; if not, the job is marked `Failed` immediately
- Job lifecycle transitions: `Queued` → `Acknowledged` → `Running` → `Completed` / `Failed`; machine status updates to `busy` during execution and returns to `idle` on completion
- The script is launched with the prompt as the first argument (`$1`); no shell interpolation
- Only declared Keychain-referenced env vars are injected; the companion app's environment is not inherited
- Working directory is the vault root
- stdout and stderr are both captured; written to CloudKit as `OutputChunk` records as output is produced, enabling near-real-time streaming to the iOS app
- The process is killed if it exceeds the agent's declared timeout; job is marked `Failed`
- Cancellation: the executor checks the job's CloudKit status periodically during execution; if `Cancelled` is detected, the process is killed
- On completion, the job execution is recorded in the local action history (agent name, prompt, status, duration, exit code)
- One job runs at a time per machine; additional queued jobs wait

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

## AskMac Distribution and Auto-Updates

### Distribution Format

- First-time install: a disk image (DMG) containing a macOS installer package (`.pkg`), distributed via GitHub Releases
- The PKG runs in macOS Installer.app, which presents a "Customize" step where optional script components can be individually selected or deselected
- Auto-updates (via Sparkle): a DMG containing just the `.app`, delivered silently in the background
- Each GitHub Release includes both artifacts: `AskMac-{version}-installer.dmg` and `AskMac-{version}.dmg`

### Auto-Updates (Sparkle)

- AskMac integrates the Sparkle 2.x framework for automatic update checking and delivery
- Sparkle is added as a Swift Package Manager dependency
- An appcast XML feed is published at a stable URL (`https://raw.githubusercontent.com/Gr8Gatsby/ask/main/docs/appcast.xml`) that Sparkle polls to discover new releases
- Each appcast entry contains: version, minimum macOS requirement, download URL, file size, and a cryptographic EdDSA signature over the download
- The EdDSA public key used to verify update signatures is embedded in the app bundle at build time
- The app checks for updates automatically on launch (at most once per day) and on demand via a "Check for Updates…" menu command
- When an update is available, Sparkle presents its standard update UI showing the release notes; the user can install immediately, skip this version, or be reminded later
- Sparkle downloads and installs the update in the background; the app relaunches into the new version
- Release notes for each version are included in the appcast entry

### Code Signing

- AskMac is signed with a Developer ID Application certificate for distribution outside the Mac App Store
- The `.app` bundle, all embedded frameworks (including Sparkle), and any helper executables are signed before packaging
- The DMG is signed after creation
- Bundle identifier: `com.kevinhill.askmac`
- Apple Developer Team ID: `B5J28L8ARB`

### Notarization and Stapling

- After signing, the DMG is submitted to Apple's notarization service (`xcrun notarytool`)
- Notarization confirms the binary is free of known malware and is properly signed with a Developer ID certificate
- After notarization, the ticket is stapled to the DMG so Gatekeeper can verify it offline
- No release is published until notarization and stapling succeed

### Release Pipeline

A GitHub Actions workflow triggers on a version tag push (`v*`) and:

1. Builds the AskMac app bundle in release configuration using the Xcode project
2. Signs the app bundle and embedded frameworks with the Developer ID certificate
3. Packages the signed app into a DMG
4. Signs the DMG
5. Submits to Apple notarization and waits for approval
6. Staples the notarization ticket to the DMG
7. Generates the Sparkle EdDSA signature for the DMG
8. Updates the appcast XML with the new release entry
9. Creates a GitHub Release and attaches the notarized DMG
10. Commits and pushes the updated appcast

### Script Bundling and Installation

**PKG component structure**

| Component | Required | Default |
|---|---|---|
| AskMac application | Yes | always installed |
| Homebrew Monitor (brew-monitor) | No | unchecked |
| Claude Code Controller (claudecode-controller) | No | unchecked |
| Codex Controller (codex-controller) | No | unchecked |
| Git Repos (github) | No | unchecked |
| Ollama (ollama) | No | unchecked |

**Bundled scripts**
- All scripts from `ask/scripts/` are bundled inside `AskMac.app/Contents/Resources/Scripts/` at build time
- Each script's `manifest.json` declares its version

**PKG script installation**
- Each optional script component's postinstall script copies files from the installed app bundle to `~/.ask/scripts/{script-id}/`
- The vault directory is created if it does not exist
- Scripts the user unchecked at the Customize step are not installed

**Script update detection**
- On each launch the app compares each bundled script's `manifest.json` version against the version already in the vault (`~/.ask/scripts/{id}/manifest.json`)
- If a bundled version is newer than the installed version, the script is added to a pending updates list
- When updates are available, the menu bar popover shows a "Script updates available" banner
- Tapping the banner shows which scripts have updates; the user may apply all or skip individually
- Scripts not present in the vault (never installed) are not shown as updates

---

### Script Dependency Checking

Scripts may declare external tool dependencies in `manifest.json` using a `requires` array. AskMac checks these before spawning the script process so the user sees a clear message instead of a cryptic crash.

**Manifest declaration:**

```json
{
  "requires": [
    {
      "id": "claude",
      "name": "Claude Code",
      "check": "claude --version",
      "min_version": "1.0.0",
      "install": "npm install -g @anthropic-ai/claude-code",
      "install_url": "https://claude.ai/code"
    },
    {
      "id": "codex",
      "name": "OpenAI Codex CLI",
      "check": "codex --version",
      "install": "npm install -g @openai/codex"
    }
  ]
}
```

| Field | Required | Description |
|---|---|---|
| `id` | ✅ | Stable identifier used for deduplication |
| `name` | ✅ | Display name shown in the UI and error messages |
| `check` | ✅ | Shell command to detect if the tool is installed (exit 0 = present) |
| `min_version` | — | Minimum acceptable version string (compared against stdout of `check`) |
| `install` | — | Install command to show the user |
| `install_url` | — | URL for full setup instructions |

**Checking behavior:**
- AskMac runs each `check` command in the user's login shell (`/bin/zsh -l -c "{check}"`) before launching the script
- The check is re-run each time the script is (re)started
- If any dependency fails: the script is placed in `missingDependencies` status and not spawned
- The menu bar popover shows the script name, which dependency failed, and the `install` command if provided
- If `install_url` is set, the menu bar item includes a link to the setup instructions
- AskMac emits a `status` block on behalf of the blocked script: `"{name} unavailable — {dep.name} not installed"`

**Version checking:**
- If `min_version` is set, AskMac captures stdout of the `check` command and looks for a semver-like version string using a regex (`\d+\.\d+\.\d+`)
- The first match is compared numerically against `min_version`; if the installed version is older, the dependency is treated as failing
- If the version cannot be parsed from stdout, the check passes (presence-only)

**Retry:**
- The user can tap "Retry" in the menu bar popover after installing the missing tool; AskMac re-runs all dependency checks and spawns the script if they pass

---

### Required Secrets (GitHub Actions)

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_CERT_P12` | Base64-encoded Developer ID Application certificate + private key |
| `CERT_P12_PASSWORD` | Password for the P12 certificate |
| `APPLE_ID` | Apple ID email for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for notarization |
| `APPLE_TEAM_ID` | Apple Developer Team ID (`B5J28L8ARB`) |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key for signing Sparkle update artifacts |

### One-Time Setup

- Generate a Sparkle EdDSA key pair using Sparkle's `generate_keys` tool; the private key is stored in the macOS Keychain (and as a GitHub secret for CI); the public key is embedded in `Info.plist` as `SUPublicEDKey`
- The Xcode project is generated from `AskMac/project.yml` using XcodeGen (`brew install xcodegen && xcodegen generate`)
- Developer ID Application certificate must be present in the local Keychain for local release builds

---

## iOS Distribution (TestFlight)

- The iOS app (`simple.ask`) is distributed via TestFlight using a GitHub Actions pipeline triggered by tags matching `ios-v*`
- The pipeline archives the iOS app, exports it as an `.ipa` using the App Store distribution method, and uploads it to App Store Connect via the App Store Connect API
- Once uploaded, the build is available in TestFlight for internal and external testing
- iOS deployment target: iOS 26.0

### iOS Release Pipeline

Trigger: push to tags matching `ios-v*` (e.g. `ios-v1.0.0`)

Steps:
1. Import iOS Distribution certificate from secrets
2. Install App Store provisioning profile
3. `xcodebuild archive` the iOS app in Release configuration
4. `xcodebuild -exportArchive` with `method: app-store-connect`
5. Upload `.ipa` to App Store Connect via `xcrun altool` with API key authentication
6. TestFlight build becomes available for testing

### Required Secrets (iOS Pipeline)

| Secret | Purpose |
|---|---|
| `IOS_DIST_CERT_P12` | Base64-encoded iOS Distribution certificate + private key |
| `IOS_CERT_P12_PASSWORD` | P12 password |
| `IOS_PROVISION_PROFILE` | Base64-encoded App Store provisioning profile (`.mobileprovision`) |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_PRIVATE_KEY` | App Store Connect API private key (`.p8` contents, base64-encoded) |

---

## Release Skills

Claude Code slash commands that cover the full release lifecycle for both platforms independently.

### `/prepare-release-mac`

Prepares a Mac release:
1. Verifies git is clean and on `main`
2. Finds the last `v*` tag; shows all commits since then grouped by type
3. Proposes a semantic version bump with reasoning
4. Confirms version with user
5. Writes release notes: a human-readable prose summary followed by a grouped commit list
6. Presents notes for user review and editing
7. Bumps `MARKETING_VERSION` in `AskMac/project.yml`
8. Adds a changelog entry to `docs/spec.md`
9. Commits the version bump

### `/prepare-release-ios`

Prepares an iOS release:
1. Verifies git is clean and on `main`
2. Finds the last `ios-v*` tag; shows all commits since then grouped by type
3. Proposes a semantic version bump
4. Confirms version with user
5. Writes release notes in the same format (prose summary + grouped commit list)
6. Bumps `MARKETING_VERSION` in the iOS Xcode project
7. Adds a changelog entry to `docs/spec.md`
8. Commits the version bump

### `/release-mac`

Cuts the Mac release:
1. Reads current version from `AskMac/project.yml`
2. Verifies git is clean and on `main`
3. Confirms with user
4. Creates annotated tag `v{version}` using the latest spec.md Mac changelog entry as the annotation body
5. Pushes the tag — triggers the `release.yml` GitHub Actions pipeline

### `/release-ios`

Cuts the iOS TestFlight release:
1. Reads current iOS marketing version from the Xcode project
2. Verifies git is clean and on `main`
3. Confirms with user
4. Creates annotated tag `ios-v{version}` using the latest spec.md iOS changelog entry
5. Pushes the tag — triggers the `ios-release.yml` pipeline

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
| 2026-03-29 | New Claude Session: compose button on home screen dispatches a new Claude Code session directly from iPhone (requires a registered "claude" action) |
| 2026-03-29 | Script enable/disable toggle: Mac menu bar popover shows a toggle per script; toggling off stops the script and clears its CloudKit blocks so iOS shows no UI for it; state persists across restarts. Scripts folder reorganized: ask-question.py moved into claudecode-controller/, legacy scripts removed. |
| 2026-03-29 | iOS button fix: UITextView inside EmojiText was swallowing touches before SwiftUI button gestures; fixed by disabling user interaction on the UITextView. Alert blocks no longer shown in iOS main UI (Mac ActionHistoryService tracks them). |
| 2026-03-29 | brew-monitor script: checks for outdated Homebrew packages (formulae + casks) every 4 hours, surfaces list as a confirmation block on iPhone, runs brew upgrade on request. claudecode-controller disconnect detection fixed to use writer transport instead of reader (reader is at EOF after SHUT_WR). |
| 2026-03-29 | Script health & preview in Mac companion: Settings > Actions tab renders live block previews inline per script (read-only, mirrors iOS block UI). Stderr from each script is captured; crash state shows last error line in Settings. Menu bar shows a warning icon next to crashed scripts. When a script crashes, an alert block is emitted to iOS and auto-cleared on successful restart. |
| 2026-03-30 | Connected Devices: Mac menu bar popover shows which iPhones have connected in the last hour. User can revoke a device (blocks it, deletes its presence record). Blocked devices manageable in Settings > General. iOS writes device heartbeat per Mac on app load (throttled to 30 min). |
| 2026-03-30 | Countdown block type: scripts emit `{ label, time }` payloads; iOS renders a live-updating relative countdown ("Next sync in about 3 hours") refreshing every 30 s. brew-monitor emits a countdown block after each check cycle. |
| 2026-03-30 | Reload Scripts button in Settings > Actions toolbar: rescans the vault directory and starts any newly discovered scripts without restarting the app. |
| 2026-03-30 | New block types: `list` (scrollable tappable rows, responds with row id) and `detail` (scrollable body up to 320pt with action buttons). GitHub script updated to use these for issue browsing and detail view. |
| 2026-03-30 | brew-monitor: add "Sync Now" confirmation block that triggers an immediate check without waiting for the 4-hour interval. |
| 2026-03-31 | Job pipeline: Mac agent configuration UI, JobExecutor service (poll → execute → stream output → history), iOS Machine Detail with agents + job history, New Job screen, Job Detail screen with streaming output. |
| 2026-03-31 | History generalized to HistoryEvent model (blockResponse, job*, scriptEnabled/Disabled/Crashed). ResponsePoller logs all block responses; ScriptManager logs enable/disable/crash; JobExecutor logs job completions. |
| 2026-03-31 | Loading states (issue #5): removed full-screen waiting spinner after block responses; MessagesView send button now shows inline spinner and is disabled while send is in flight. All loading feedback is component-level. |
| 2026-03-31 | Git Repos script: replaced GitHub issues script with local git repository monitor. Scans ~ for all git repos, prioritizes unpushed commits, supports Commit (with Ollama-generated message) / Push / Pull / Fetch / Discard Changes from iPhone. |
| 2026-04-01 | Script CloudKit emission indicator: each script row in the menu bar popover shows a cloud icon to the left of the toggle. The icon appears only after the script has emitted at least one block since app start. Green outline = script currently has active live blocks; charcoal outline = has emitted before but no active blocks now. |
| 2026-04-01 | Push notification navigation fixes: (1) Cold-start: scriptID is persisted to UserDefaults on notification tap and consumed by HomeView after first load, so tapping a notification while the app is killed navigates correctly. (2) Block freshness: navigating via notification now triggers an immediate load so the confirmation block is visible without a race. (3) Subscription reliability: CloudKit subscriptions are re-saved on every launch so stale settings from previous installs are replaced. |
| 2026-04-01 | Polling latency reduced: idle poll interval reduced from 30s to 5s. ScriptDetailView runs its own 5s poll loop while open so updates arrive even if HomeView's background poll is paused. |
| 2026-04-01 | iOS TestFlight: GitHub Actions pipeline triggered by ios-v* tags; iOS Distribution cert + App Store provisioning profile + ASC API key auth; deployment target iOS 26.0. Release skills: /prepare-release-mac, /prepare-release-ios, /release-mac, /release-ios — version bump, prose+commit release notes, spec changelog, annotated tag creation. |
| 2026-04-01 | Distribution: AskMac installer packaged as a PKG inside a DMG, distributed via GitHub Releases. PKG has required app component + optional per-script components (all unchecked by default). Sparkle 2.x integrated for silent app-only auto-updates via appcast. Bundled scripts in app bundle enable update detection: menu bar popover shows pending script updates and prompts user to apply. Xcode project generated via XcodeGen (project.yml). GitHub Actions release pipeline triggered on version tags. |
| 2026-04-01 | Script dependency checking: manifest.json `requires` array declares external tool dependencies (name, check command, min version, install instructions). AskMac checks deps before spawning a script; failed scripts enter missingDependencies status with install instructions shown in the menu bar popover and a status block emitted to iPhone. claudecode-controller, codex-controller, and ollama manifests updated with requires declarations. |
| 2026-04-02 | Mac Scripts home view: replaced the tabbed Settings panel with a NavigationSplitView home + detail experience. Sidebar lists all scripts with icon, status indicator, and enable/disable toggle. Detail panel shows the script header (name, version, description) and all active blocks rendered with full interactivity using BlockPreviewView. General settings (machine name, vault path, agent sessions, about) moved to a gear-button sheet within the Scripts window. "Actions" renamed to "Scripts" throughout the Mac app. Menu bar popover "Settings" button renamed to "Scripts". |
| 2026-04-02 | Mac Feed view: added a "Feed" item at the top of the Scripts sidebar. Selecting it shows a chronological list of script interactions and lifecycle events (block responses, enable/disable, crashes) from ActionHistoryService. Sidebar minimum width set to 220pt so script names are fully visible. |
| 2026-04-02 | Mac script detail card: replaced the flat header with a rich card showing brand colors (Claude Code cream, GitHub dark), large icon, name, version, type badge (Tile/Feed), description, ID, schedule, status badge, enable/disable toggle, and a dependencies section (all declared deps with installed/missing state and retry). ManagedScript now carries scriptType, schedule, and requires from the manifest. Machine settings moved from a gear-button sheet to a "Machine" sidebar item with a full-panel Form view. |
| 2026-04-02 | Mac app navigation restructured: Scripts, Feed, and Machine are now top-level tabs in the window toolbar (segmented picker, principal placement). Scripts tab retains its NavigationSplitView sidebar; Feed and Machine are full-window panels with no sidebar. This allows each tab to independently decide its layout. Window renamed to "Ask". |
| 2026-04-02 | Mac menu bar popover simplified: shows only machine name + status dot, scripts list (icon, name, cloud indicator, toggle), a labelled "Restart Scripts" button with proper hit target, and a single "Open Ask" button. iCloud sync and connected devices moved to Machine tab. |
| 2026-04-02 | Mac Machine tab enhanced: Cloud section shows iCloud sync status (last heartbeat, interval) and Connected iPhones section shows device name, last-seen time, truncated device ID, and enabled/disabled toggle with device count. HeartbeatService added to Scripts window environment. |
| 2026-04-02 | Mac Feed tab: NavigationSplitView with an analytics sidebar (total count + per-script breakdown with event count and last activity) and a main feed list. Clicking a feed item opens a detail sheet showing summary, formatted timestamp, and detail text. blockResponse history icon changed to hand.point.up.left. |
| 2026-04-02 | Mac Blocks tab: local block builder (no service connection). Palette sidebar with 14 block types grouped by Interactive / Informational / AI & Sessions. Canvas shows live BlockPreviewView renders with move-up/move-down/delete controls on hover. JSON panel shows pretty-printed block array with copy button. Panel toggle in toolbar. |
| 2026-04-02 | Feed sidebar type filters: "By Type" section added with Crashes, Responses, Enabled, Disabled rows (shown only when count > 0). Filter uses typed FeedFilter enum (all / kind / source) replacing the old String? source-only filter. Crash detail: crashes without stderr simply have no Detail row in the sheet — this is correct; no data was lost. |
| 2026-04-02 | Mac brand card icons: dark-brand cards (GitHub) now apply SVG white-fill rewrite to the card icon, matching the sidebar dark-mode behaviour. svgToWhite() extracted to a file-level helper. Color scheme override on brand cards is now conditional — unbranded cards do not force a color scheme, correctly adapting to the system setting. |
