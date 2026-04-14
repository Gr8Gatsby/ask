# Codex-2 Session Flow

How the codex-2 script supervises OpenAI Codex CLI sessions and surfaces them to your iPhone.

---

## What Is Codex-2?

Codex-2 is a Python script that runs silently on your Mac (as a child of AskMac). Its job is to:

1. Launch Codex CLI sessions in tmux windows
2. Watch what Codex is doing and send status updates to your iPhone
3. Route permission requests to your iPhone for approval
4. Relay your responses back to Codex

It never talks to CloudKit directly — all iPhone communication flows through AskMac via a local protocol called MCP (Model Context Protocol).

---

## 10,000-Foot View

The big picture: your iPhone talks to CloudKit, AskMac syncs CloudKit, codex-2 drives AskMac.

```
  YOUR IPHONE                    YOUR MAC                      TERMINAL
  ───────────                    ────────                      ────────

  [+ button]  ─── tap ────────▶  codex-2 shows a             
                                 repo picker card              
                                                               
  [repo list] ─── pick repo ──▶  codex-2 shows a             
                                 mode picker card              
                                                               
  [Interactive                                                 
   or Headless] ── pick ──────▶  codex-2 launches  ─────────▶  tmux opens
                                 Codex in tmux                  Codex starts
                                                               
                                 Codex tells codex-2 ◀────────  SessionStart hook
                                 "I started"                   
                                                               
  [Session tile                                                
   appears] ◀── card pushed ──   codex-2 sends status         
                                 to iPhone every 2s            
                                                               
  [Approval                                                    
   card] ◀────── card pushed ──  codex-2 received  ◀─────────  "Can I run Bash?"
                                 permission request             (PreToolUse hook)
                                                               
  [Allow / Deny] ── tap ───────▶  codex-2 replies  ──────────▶  Codex continues
                                                               
  [Session tile                                                
   disappears] ◀── cleared ───   codex-2 received  ◀─────────  Codex finished
                                 "I stopped"                    (Stop hook)
```

---

## Component Map

There are six distinct pieces. Here is what each one does and how they connect.

```
  ┌──────────────────────────────────────────────────────────────┐
  │  YOUR IPHONE                                                 │
  │                                                              │
  │   HomeView          ScriptDetailView      SessionChatView    │
  │   ─────────         ────────────────      ───────────────    │
  │   Shows the         Shows live blocks     Shows the chat     │
  │   + button and      for one session:      thread for a       │
  │   a count of        status, TUI menus,    session plus       │
  │   active sessions   permission requests   linked approvals   │
  │                                                              │
  │   BlockViews — draws every card type (tiles, confirmations,  │
  │   alerts, pickers) from CloudKit data                        │
  │                                                              │
  │   iOSCloudKitService — polls CloudKit and feeds the views    │
  └──────────────────────────────────────────────────────────────┘
              ▲  reads cards          │  writes responses
              │  from CloudKit        │  to CloudKit
              │                       ▼
  ┌──────────────────────────────────────────────────────────────┐
  │  CLOUDKIT  (Apple's cloud database)                          │
  │                                                              │
  │  Holds "block" records — each block is one card on iPhone.  │
  │  Blocks have a type, a payload, and a TTL (expiry time).    │
  │  AskMac writes them. iPhone reads them.                      │
  └──────────────────────────────────────────────────────────────┘
              ▲  writes/clears        │  blocks arrive
              │  block records        │  via sync
              │                       ▼
  ┌──────────────────────────────────────────────────────────────┐
  │  ASKMAC  (menu bar app on your Mac)                          │
  │                                                              │
  │  CloudKit layer — reads and writes block records             │
  │  MCP server    — exposes tools to scripts (emit_block,       │
  │                  clear_block, detect_tui, send_key, …)       │
  │  Push service  — sends APNs when an urgent block arrives     │
  │  Socket proxy  — forwards hook messages from codex-2's       │
  │                  Unix socket into the MCP tool system        │
  └──────────────────────────────────────────────────────────────┘
              ▲  tool responses       │  tool calls (JSON-RPC)
              │  over stdio           │  over stdio
              │                       ▼
  ┌──────────────────────────────────────────────────────────────┐
  │  CODEX-2  (Python script, child process of AskMac)           │
  │                                                              │
  │  Session registry — in-memory map of all active sessions:    │
  │    session_id → { cwd, tmux_target, pid, is_working, … }    │
  │                                                              │
  │  Poll loop  — runs every 2s per session; reads the tmux      │
  │               pane and emits a fresh status tile             │
  │                                                              │
  │  Heartbeat  — runs every 30s; rediscovers sessions that      │
  │               started without going through the picker       │
  │                                                              │
  │  Unix socket — receives hook events from Codex hooks         │
  └──────────────────────────────────────────────────────────────┘
       ▲  hook events        │  tmux commands        │  MCP tool calls
       │  via Unix socket    │  (list-panes,         │  (detect_tui,
       │                     │   send-keys, …)       │   send_key, …)
       │                     ▼                       ▼
  ┌────────────────┐   ┌────────────────────────────────────────┐
  │  CODEX HOOKS   │   │  TERMINAL-MANAGER                      │
  │  (Python)      │   │  (Python MCP, child of AskMac)         │
  │                │   │                                        │
  │  Five hooks    │   │  Owns the tmux pane registry.          │
  │  installed     │   │  Reads pane content and detects TUI    │
  │  into Codex:   │   │  patterns (numbered menus, slash       │
  │                │   │  commands, toggle menus).              │
  │  SessionStart  │   │  Injects keystrokes and text on        │
  │  PreToolUse    │   │  behalf of codex-2.                    │
  │  PostToolUse   │   │                                        │
  │  Stop          │   └────────────────────────────────────────┘
  │  UserPrompt    │              │  reads / writes panes
  │                │              ▼
  │  Each hook     │   ┌────────────────────────────────────────┐
  │  sends JSON    │   │  TMUX  (terminal multiplexer)          │
  │  to codex-2's  │   │                                        │
  │  Unix socket   │   │  One shared session named "codex".     │
  │  and exits     │   │  Each project gets its own window:     │
  └────────────────┘   │                                        │
                        │    codex session                       │
                        │    ├── window: ask   → Codex process  │
                        │    └── window: jokes → Codex process  │
                        └────────────────────────────────────────┘
```

---

## Block Types

Every card on iPhone is a "block" in CloudKit. Here are the blocks codex-2 uses:

| Block ID | Card Type | When It Exists | What It Shows |
|---|---|---|---|
| `codex2-start` | Repo picker | Always (while idle or active) | List of repos + the + button |
| `codex2-mode-pick` | Confirmation | Only during launch (120s TTL) | Interactive vs Headless choice |
| `codex2-session-{id}` | Agent session tile | While session is live (300s TTL, refreshed every 30s) | Project name, status, last message |
| `codex2-menu-{id}` | Confirmation | While a numbered menu is on screen in Codex | Menu choices from the TUI |
| `codex2-slash-{id}` | Confirmation | While the slash command list is on screen | `/model`, `/help`, etc. |
| `codex2-toggle-{id}` | Confirmation | While a toggle menu is on screen | Toggle settings in the TUI |
| `codex2-perm-{id}-{tool}` | Confirmation | Until you approve or deny | "Codex wants to run Bash: …" |
| `codex-2-tile` | Tile badge | While any session exists | Session count, or "no sessions" |

---

## Key Flows

### 1. Launching a Session

```
  iPhone                codex-2                tmux          Codex CLI
  ──────                ───────                ────          ─────────

  tap +          ──▶   emit repo picker card
  
  pick "jokes"   ──▶   store pending path
                        emit mode picker card
  
  pick           ──▶   clear picker
  "Interactive"         save setting to disk
                        ─────────────────────▶  create or
                                                reuse window
                                                "codex:jokes"
                        ─────────────────────▶  run: codex
                                                              starts up
                                                ◀──────────── SessionStart
                                                              hook fires
                        ◀── socket message ───
                        register session
                        start poll loop (2s)
                        open Terminal.app
                        re-emit repo picker
  
  session tile   ◀──   emit agent_session
  appears               block to CloudKit
```

**What "register session" stores:**

```
  session_id:   "tmux-codex:jokes.0"    ← stable, survives restarts
  cwd:          "/Users/kevin/code/jokes"
  tmux_target:  "codex:jokes.0"         ← pane address for tmux commands
  tty:          "/dev/ttys004"           ← terminal device
  pid:          48291                    ← foreground process ID
  is_headless:  false                    ← Terminal.app is attached
  is_working:   false                    ← Codex is idle
```

---

### 2. Permission Request (Tool Approval Gate)

This is a **blocking** flow. Codex literally waits for your response before it can continue.

```
  Codex CLI             hook              codex-2           iPhone
  ─────────             ────              ───────           ──────

  "can I run
   Bash: rm -rf /tmp?"
  
  ← PreToolUse
    hook fires
                  write JSON ──▶  receive on socket
                  to socket       emit permission card
                                  to CloudKit          ──▶  card appears
                                                             "Allow Bash?"
                                  
                                  wait for response    ◀──  tap "Allow"
                                  
                                  write "allow"
                                  to hook stdin
  receives ──────────────────────────────────────────
  "allowed"
  continues
                                  ◀── PostToolUse
                                       hook fires
                                  update session tile
                                  (is_working = false)      tile updates
```

---

### 3. The Poll Loop (Status Updates)

Runs every 2 seconds in the background for each active session.

```
  codex-2              terminal-manager         tmux pane
  ───────              ────────────────         ─────────

  call detect_tui ──▶  read pane content  ──▶  capture text
  
                       recognize pattern:
                       ┌─ numbered_menu?  → structured options
                       ├─ slash_commands? → list of /commands
                       ├─ toggle_menu?    → on/off settings
                       └─ none            → plain output
  
                       return { pattern_id, result } ──▶  codex-2 receives
  
  if pattern changed:
    clear old TUI block
    emit new confirmation block → iPhone shows updated menu card
  
  always:
    recompute session tile payload
    if payload hash changed:
      emit agent_session block → iPhone tile refreshes
    (skip CloudKit write if nothing changed — saves bandwidth)
```

---

### 4. Session End

```
  Codex CLI         Stop hook         codex-2                iPhone
  ─────────         ─────────         ───────                ──────

  finishes
  (or is stopped)
  
  ← Stop hook fires
                    write JSON ──▶  receive on socket
                    to socket
                                    cancel poll loop task
                                    unregister from
                                    terminal-manager
                                    clear session block ──▶  tile disappears
                                    
                                    if no sessions left:
                                    emit "no sessions" tile   badge clears
```

---

## Session Identity and Deduplication

Session IDs are designed to be **stable across restarts**. The same Codex process in the same tmux window always gets the same ID, even if codex-2 crashes and restarts.

```
  ID format:  "tmux-codex:{window_name}.{pane_index}"
  Example:    "tmux-codex:jokes.0"

  This ID is derived from the tmux window name, not a random UUID,
  so it survives codex-2 restarts and is safe to use as a CloudKit record name.
```

**How duplicates are prevented:**

```
  At startup, codex-2 runs _discover_active_sessions() which scans
  all tmux panes for running Codex processes.

  Before registering a discovered session it checks:
  
    1. Is "tmux-codex:jokes.0" already in _sessions?  → skip (exact match)
    2. Does any session already have tmux_target "codex:jokes"?  → skip (same window)
  
  This prevents double-registration when:
  - codex-2 restarts while Codex is running
  - A hook fires at the same time as discovery
```

---

## What Can Go Wrong

| Symptom | Likely Cause |
|---|---|
| Session appears twice on iPhone | Discovery used `window_index` instead of `window_name` (fixed in v1.5.14) |
| Mode picker shows blank button | SwiftUI reused stale view state from previous picker (fixed — view now gets new identity when content changes) |
| Session stuck "starting" | SessionStart hook didn't fire — check `~/.codex/hooks.json` exists |
| Approval card never appears | Unix socket path mismatch — check `ASK_SOCKET_PATH` env var |
| Session tile disappeared but Codex still running | TTL expired and heartbeat failed to refresh — check AskMac is running |
