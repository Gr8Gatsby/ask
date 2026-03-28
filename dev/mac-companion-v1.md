# Dev Design: Mac Companion — Service Layer v1

## Goal
Implement the core service pipeline for the AskMac companion app: machine registration, heartbeat, job watching, script execution, and output streaming via CloudKit. Exposes one configured agent that can receive a job from the iOS app and execute it.

## Scope
- CloudKit schema and service layer
- Machine heartbeat (registers this Mac, keeps status alive)
- Job watcher (polls CloudKit for queued jobs assigned to this machine)
- Job executor (runs the configured script, streams output chunks back)
- Minimal menu bar UI showing current status
- AppSettings persisted to UserDefaults

## Out of Scope (v1)
- Cryptographic pairing / job signature verification (marked as TODO)
- CKSubscription push-based job delivery (polling used instead)
- Full agent management UI
- Vault directory enforcement at OS level
- Multiple agents (one agent configured in settings)

## CloudKit Container
- ID: `iCloud.simple.ask` (matches iOS bundle ID `simple.ask`)
- Database: private (`container.privateCloudDatabase`)
- Zone: default zone
- Schema auto-created by CloudKit in development environment on first save

## Record Types

### Machine
| Field | Type | Notes |
|---|---|---|
| machineID | String | Also the CKRecord.ID recordName |
| name | String | User-assigned display name |
| platform | String | Always "macOS" |
| lastHeartbeat | Date | Updated every 30s |
| status | String | "idle" or "busy" |
| activeJobID | String? | Set while a job is running |

### Agent
| Field | Type | Notes |
|---|---|---|
| agentID | String | UUID, also used in recordName |
| machineID | String | Owner machine |
| name | String | Display name |
| scriptName | String | Filename within vault directory |
| timeout | Int | Max runtime in seconds |
| capabilityNetwork | Bool | |
| capabilitySubprocess | Bool | |
| capabilityReadPaths | [String] | Declared read directories |
| capabilityWritePaths | [String] | Declared write directories |
| capabilityEnvKeys | [String] | Keychain item names to inject |

### Job
| Field | Type | Notes |
|---|---|---|
| jobID | String | UUID, also recordName |
| machineID | String | Target machine |
| agentID | String | Target agent |
| prompt | String | User input |
| status | String | queued/acknowledged/running/completed/failed/cancelled |
| createdAt | Date | |
| startedAt | Date? | |
| completedAt | Date? | |
| exitCode | Int? | |

### OutputChunk
| Field | Type | Notes |
|---|---|---|
| jobID | String | Parent job |
| sequence | Int | Ordering within job |
| text | String | Output text |
| isError | Bool | true = stderr |
| timestamp | Date | |
recordName = `{jobID}-{sequence:08d}` for stable ordering

## Service Architecture

```
AskMacApp (MenuBarExtra)
  ├── AppSettings        — UserDefaults, machineID, name, vault, one agent config
  ├── CloudKitService    — CKContainer wrapper, all CRUD operations
  ├── HeartbeatService   — Timer(30s) → upsert Machine record
  ├── JobWatcher         — Timer(10s) → fetch queued jobs → JobExecutor
  └── JobExecutor        — Process + Pipe → OutputChunk records + Job status updates
```

## Execution Flow

1. App starts → `HeartbeatService` writes Machine record (creates or updates)
2. `JobWatcher` polls every 10s: `SELECT * FROM Job WHERE machineID = X AND status = "queued" ORDER BY createdAt`
3. Job found → `JobExecutor.execute(job:agent:)`
4. Executor updates job status: `acknowledged` → `running`
5. `Process` launched: `[vaultPath/scriptName, prompt]`, no shell, env isolated to declared Keychain keys
6. stdout/stderr read via `Pipe` in async loop
7. Each chunk → `OutputChunk` record saved to CloudKit (sequence counter incremented)
8. Process exits → job updated to `completed`/`failed` with exit code
9. `HeartbeatService` notified → machine status returns to `idle`

## Prompt Injection Prevention
The prompt is always passed as a distinct argument element in the `Process.arguments` array, never interpolated into a shell command string. `Process.launchPath` is set to the absolute script path directly — no shell (`/bin/sh -c`) involvement.

## Capability Enforcement (v1)
- Script must be within the registered vault directory (path validated before launch)
- Process environment: only declared Keychain items injected; `Process.environment` set explicitly (no inheritance)
- Process killed after `timeout` seconds via `Process.terminate()`
- TODO v2: macOS sandbox profiles per child process

## Signature Verification
TODO: All jobs must be signed by the paired iOS device's Ed25519 private key. The Mac companion verifies the signature against the stored iOS public key before executing. Not implemented in v1 — marked with `// TODO: verify signature` at the execution gate.

## Files
```
AskMac/
  Package.swift
  Sources/AskMac/
    AskMacApp.swift
    Settings/
      AppSettings.swift
    Models/
      CloudKitSchema.swift
    Services/
      CloudKitService.swift
      HeartbeatService.swift
      JobWatcher.swift
      JobExecutor.swift
    Views/
      MenuBarView.swift
      SettingsView.swift
```
