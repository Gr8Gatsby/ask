# Ask

Ask lets you supervise AI agents and scripts running on your Mac from your iPhone. Scripts push interactive UI cards ("blocks") to the phone via CloudKit — confirmations, status updates, prompts, lists — and your responses are delivered back to the script in real time.

```
Mac script  ──blocks──▶  CloudKit  ──▶  iPhone
iPhone tap  ──response──▶  CloudKit  ──▶  Mac script
```

---

## Apps

**Ask** (iOS) — displays blocks from all connected Macs, routes responses back, and shows a live home-screen tile per script.

**AskMac** (macOS menu bar) — runs scripts, bridges their MCP output to CloudKit, polls for responses, and delivers them back to the script over stdin.

---

## How it works

Scripts are plain executables (Python, Swift, shell) that live in `~/.ask/scripts/`. Each has a `manifest.json` and communicates over MCP stdio. When a script calls `emit_block`, AskMac writes a CloudKit record; the iOS app polls and renders it. When the user responds, iOS writes a response record; AskMac polls and delivers it to the script's stdin.

---

## Documentation

| Document | Description |
|---|---|
| [docs/spec.md](docs/spec.md) | Functional specification — what the system does |
| [docs/architecture.md](docs/architecture.md) | End-to-end technical architecture |
| [docs/design.md](docs/design.md) | Block design reference for script authors |
| [docs/blocks.md](docs/blocks.md) | Complete block type reference with payload schemas and iOS rendering |

### Feature specs

| Document | Description |
|---|---|
| [docs/specs/new-blocks.md](docs/specs/new-blocks.md) | Progress, Log, Image, Multi-select, Toggle blocks |
| [docs/specs/compact-blocks.md](docs/specs/compact-blocks.md) | Compact iOS block layout |
| [docs/specs/offline-heartbeat.md](docs/specs/offline-heartbeat.md) | Offline detection, heartbeat, and response queue |
| [docs/specs/design-job-pipeline.md](docs/specs/design-job-pipeline.md) | Job pipeline design |

---

## Writing scripts

Scripts are the main extension point. See [docs/blocks.md](docs/blocks.md) for all available block types and their payloads. Use the `/ask-script` skill in Claude Code to generate a complete, working script from a description.
