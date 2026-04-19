# Ask

Ask lets you supervise AI agents and scripts running on your Mac from your iPhone. Push interactive UI cards — confirmations, status updates, prompts, lists — to your phone in real time and respond without touching the Mac.

```
Mac script  ──emit_block──▶  CloudKit  ──▶  iPhone renders block
iPhone tap  ──response───▶  CloudKit  ──▶  Mac script stdin
```

**The apps handle the pipes. Scripts are where the value lives.**

---

## Get Started

### 1. Download Ask for Mac

**[⬇ Download the latest release →](https://github.com/Gr8Gatsby/ask/releases/latest)**

Open the `.pkg` installer and follow the prompts. Ask will appear in your menu bar.

### 2. Install Ask on iPhone

Ask for iPhone is available on the [App Store](https://apps.apple.com/app/ask/id6744642445) and [TestFlight](https://testflight.apple.com/join/ask).

### 3. Sign in to the same iCloud account

Both devices must be signed into the same iCloud account. Ask uses CloudKit — no extra accounts to create, no servers to run.

Open Ask on your Mac and Ask on your iPhone. Your Mac will appear in the iOS app within seconds.

---

The iOS app and Mac companion exist to solve one problem: reliably getting interactive UI to your phone and getting responses back. Once that channel exists, the interesting work is entirely in the scripts you write on top of it.

---

## Scripts

Scripts are plain executables — Python, Swift, shell — that run as persistent daemons managed by the Mac companion. Each script connects to the daemon over stdio using the MCP (JSON-RPC 2.0) protocol, emits blocks to the iOS app, and receives user responses back through the same channel.

There are no frameworks to install, no SDKs to configure, and no cloud accounts beyond iCloud. A working script is a single file with a `manifest.json`.

### Anatomy of a script

**`manifest.json`** — Tells AskMac how to discover and launch the script:

```json
{
  "id": "my-script",
  "name": "My Script",
  "version": "1.0.0",
  "description": "Does something useful and surfaces it on iPhone",
  "entry": "main.py",
  "icon": "bolt.fill"
}
```

**The MCP client** — A minimal JSON-RPC layer over stdin/stdout. Scripts send tool calls to the daemon and receive responses back. The full client is ~60 lines of Python or Swift and is generated for you by the `/ask-script` skill.

```python
class MCPClient:
    async def emit_block(self, block_id, block_type, payload, ttl=None):
        # Writes a CloudKit record → iOS app renders it within seconds
        await self._rpc('tools/call', {
            'name': 'emit_block',
            'arguments': {'blockId': block_id, 'blockType': block_type, 'payload': payload}
        })

    async def clear_block(self, block_id):
        # Removes the block from the iOS app
        await self._rpc('tools/call', {'name': 'clear_block', 'arguments': {'blockId': block_id}})
```

**Emitting a block and waiting for a response** — the core interaction pattern:

```python
block_id = 'my-script-confirm'

# Register response handler BEFORE emitting (avoids race with CloudKit delivery)
response_future = client.wait_for_block_response(block_id, timeout=300)

await client.emit_block(block_id, 'confirmation', {
    'title': 'Deploy to production?',
    'body': 'This will push v2.4.1 to all production servers.',
    'options': ['Deploy', 'Cancel']
})

response = await response_future   # blocks until the user taps on iPhone
if response == 'Deploy':
    run_deployment()

await client.clear_block(block_id)
```

**The tile** — a persistent home-screen status card, re-emitted on a heartbeat:

```python
await client.emit_block('my-script-tile', 'tile', {
    'label': '3 repos need attention',
    'status_color': 'orange',
    'action_required': True
}, ttl=600)  # auto-expires after 10 minutes; heartbeat re-emits before then
```

### Real example: Claude Code controller

The `claudecode-controller` script monitors every Claude Code session running on the Mac. When Claude needs to use a tool, the script surfaces an `agent_session` block on iPhone — showing what Claude wants to do — and blocks until the user approves or denies. Claude proceeds based on the response.

```
Claude Code needs to run bash  →  agent_session block on iPhone
User taps "Allow"              →  response delivered to script stdin
Script exits 0                 →  Claude runs the command
```

This is the core pattern repeated across all supervision scripts: detect something that needs human attention, emit a block, wait for a response, act on it.

### Real example: Homebrew monitor

Not every script needs a response. The `brew-monitor` script runs every 4 hours, checks for outdated packages, and keeps you informed without requiring any action on your part.

```
Every 4 hours: brew outdated  →  status block: "Checking for updates…"
0 packages outdated           →  status block: "Homebrew up to date" (green)
                              →  feed_item logged to Feed tab
                              →  countdown: "Next check in 4h"
4 packages outdated           →  confirmation block: "4 updates available"
User taps "Upgrade All"       →  brew upgrade runs, status updates live
                              →  alert: "Upgrade complete — 4 packages"
```

The feed and status blocks are purely ambient — they appear on your phone and expire on their own. No tap required. The confirmation only appears when there's something to act on.

```python
# Feed pattern: emit → expire → repeat. No response, no interaction.
await client.emit_block('brew-status', 'status', {
    'label': 'Homebrew up to date',
    'icon': 'checkmark.circle',
    'color': 'green',
}, ttl=CHECK_INTERVAL)  # auto-expires before the next check

await client.emit_block(f'brew-check-{uuid.uuid4()}', 'feed_item', {
    'title': 'Homebrew check complete',
    'body': 'All packages up to date.',
    'icon': 'checkmark.circle.fill',
})

await client.emit_block('brew-next-check', 'countdown', {
    'label': 'Next Homebrew check',
    'time': next_check_timestamp,
}, ttl=CHECK_INTERVAL + 300)
```

This is the other core pattern: **scheduled ambient reporting** — run on a timer, emit what happened, expire automatically. Your phone stays informed without demanding attention.

---

## Blocks

Blocks are the UI primitives your script pushes to the iOS app. Choose the block type that fits what you need to communicate.

### Implemented

| Block | Type string | Response? | When to use |
|---|---|:---:|---|
| **Confirmation** | `confirmation` | ✅ | Binary or multi-choice decisions — "Deploy?", "Approve?" |
| **Prompt** | `prompt` | ✅ | Free-text input — "What's the commit message?" |
| **Chat Prompt** | `chat_prompt` | ✅ | Conversational back-and-forth with message history |
| **Picker** | `picker` | ✅ | Select one item from a named list |
| **List** | `list` | ✅ | Tappable rows — browse repos, choose a model, pick a branch |
| **Detail** | `detail` | ✅ | Long-form content + action buttons — show a diff, a log, a summary |
| **Agent Session** | `agent_session` | ✅ | Interactive card for Claude Code / Codex sessions |
| **Start Session** | `start_session` | ✅ | Repo picker to launch a new agent session from iPhone |
| **Status** | `status` | — | Labeled status with color — "Build: passing" |
| **Alert** | `alert` | — | One-shot notification — "Brew upgrade complete" |
| **Info Card** | `info_card` | — | Key-value data display |
| **Icon Card** | `icon_card` | — | Script identity card with large icon |
| **Tile** | `tile` | — | Persistent home-screen summary, refreshed on heartbeat |
| **Countdown** | `countdown` | — | Live countdown to a timestamp — "Next check in 3h 12m" |
| **Feed Item** | `feed_item` | — | Entry in the chronological Feed tab |
| **Claude Message** | `claude_message` | — | Claude's last message rendered in formatted markdown |

Full payload schemas and iOS rendering details: [`docs/blocks.md`](docs/blocks.md)

### Planned

`progress` · `log` · `image` · `multi_select` · `toggle`

---

## MCP Tools

Scripts call these four tools through the daemon over stdio:

| Tool | What it does |
|---|---|
| `emit_block` | Write a block to CloudKit → rendered on iPhone within seconds |
| `clear_block` | Remove a block from the iOS app |
| `get_schema` | Fetch payload schemas for all block types |
| `list_terminal_sessions` | Enumerate interactive terminal sessions on the Mac (filter by process name) |

`list_terminal_sessions` is particularly useful for supervision scripts — it lets a script find the TTY of a running Claude Code or Codex process without any manual configuration:

```python
sessions = await client.list_terminal_sessions(filter='claude')
# → [{'pid': 1234, 'name': 'node', 'tty': 's003', 'cwd': '/Users/kevin/project', 'tab_title': 'claude'}]
```

---

## AI-powered development

The fastest way to build a new script is with Claude Code. This repo ships skills that know the full system — block schemas, MCP protocol, critical patterns — so you don't have to explain any of it.

### `/ask-script` — Generate a complete script

Describe what you want to build. The skill generates a fully working script with the correct manifest, MCP client, block emissions, response handling, test mode, and all the non-obvious patterns (unbuffered stdout, callback-before-emit, SIGPIPE handling, non-blocking stdin).

```
/ask-script monitor my git repos and let me push, pull, or commit from iPhone
```

### `/deploy-scripts` — Deploy to your vault

After editing any script in the repo, run this to sync it to your live vault and restart it in the Mac companion.

```
/deploy-scripts git-repos
/deploy-scripts all
```

### `/vault-setup` — Switch between dev and prod

```
/vault-setup dev   # point AskMac at ask/scripts/ in this repo
/vault-setup prod  # point AskMac at ~/.ask/scripts/
```

### Release skills

| Skill | What it does |
|---|---|
| `/prepare-release-mac` | Bumps Mac version, writes release notes, updates changelog, commits |
| `/release-mac` | Creates annotated tag `v{version}`, pushes → triggers local build + publish |
| `/prepare-release-ios` | Bumps iOS version, writes release notes, commits |
| `/release-ios` | Creates annotated tag `ios-v{version}`, pushes → triggers TestFlight upload |

---

## Repository layout

```
ask/                        iOS app (Xcode project)
  ask/                      App source (SwiftUI)
  scripts/                  Example scripts — source of truth for vault deployments
    brew-monitor/           Homebrew package monitor (Swift binary)
    claude-3/               Claude Code session supervisor (Python)
    codex-3/                Codex CLI session supervisor (Python)
    github/                 Git repo monitor (Python)
    ollama/                 Ollama chat + update manager (Python)

AskMac/                     Mac companion app (Swift Package + Xcode project)
  Sources/AskMac/           Menu bar app
    Services/               ScriptManager, MCPConnection, CloudKitService, …
    Views/                  MenuBarView, SettingsView, …
  Sources/AskMacCore/       Shared core (TerminalMonitorService)

installer/                  PKG installer components
  distribution.xml          productbuild distribution spec
  scripts/*/postinstall     Per-script postinstall for vault installation

scripts/                    Local release scripts
  build-release.sh          Sign, notarize, package, publish Mac release
  release-ios.sh            Archive and upload iOS build to TestFlight

docs/
  blocks.md                 Complete block type reference (payload schemas + rendering)
  architecture.md           End-to-end technical architecture
  developer-guide.md        Full developer reference
  spec.md                   Functional specification
  design-installer.md       PKG installer design
```

---

## Documentation

| | |
|---|---|
| [docs/developer-guide.md](docs/developer-guide.md) | Complete reference: scripts, blocks, MCP tools, skills, Mac and iOS development |
| [docs/blocks.md](docs/blocks.md) | All block types with full payload schemas and iOS rendering |
| [docs/architecture.md](docs/architecture.md) | End-to-end technical architecture |
| [docs/spec.md](docs/spec.md) | Functional specification |
