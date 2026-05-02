---
name: validate-messaging
description: End-to-end test that messages from the iPhone/web app reach a live Claude Code or Codex tmux/terminal session and that responses flow back. Lets Claude self-verify the supervisor pipeline without asking the user to reinstall AskMac.
argument-hint: [claude|codex|both]  (default: both)
---

Validates the **iPhone → CloudKit → AskMac → daemon → terminal-manager → tmux/tty → agent → hook → CloudKit → iPhone** messaging round-trip on the dev box, end to end. Use this whenever you've changed claude-3, codex-3, terminal-manager, or any of the hooks and want to confirm the round trip still works.

## What this tests

```
[test driver]                                                          [agent]
     │                                                                    ▲
     ▼                                                                    │
 mock /respond ──→ daemon socket ──→ inject_tty/send_text ──→ tty/tmux ──┘
     ▲                                                                    │
     │                                                                    ▼
 blocks.json ◀─── emit_block ◀─── _handle_user_prompt ◀─── hook fires ◀───┘
```

If a message goes in via the test driver and a fresh hook event lands in the daemon log within a few seconds, the round trip is healthy.

## When to use vs. NOT use

**Use when:**
- You changed code in `ask/scripts/claude-3/`, `ask/scripts/codex-3/`, the hooks, or `terminal-manager`
- A user reports a session disappearing, messages not arriving, or hook events not firing
- You want to confirm a fix before pushing

**Do NOT use when:**
- You only changed the web/iOS UI (no daemon changes) — run `npm run dev` and inspect manually
- The user is mid-session in the target tmux pane — the test injects a visible message into their terminal

## Prerequisites (assumed live on the dev box)

These must be running before the skill executes. The skill **detects and reports**, but does NOT auto-start AskMac (a debugger is usually attached):

| Component | Check | If missing |
|---|---|---|
| AskMac (Xcode build) | `pgrep -fl AskMac` | Tell the user to launch from Xcode |
| claude-3 daemon | `test -S ~/.ask/sockets/claude-3.sock` | Reload scripts in AskMac (↺ in Settings → Actions) |
| codex-3 daemon | `test -S ~/.ask/sockets/codex-3.sock` | Same |

These can be started by the skill if missing:

| Component | Check | Auto-start command |
|---|---|---|
| Mock server | `curl -sS http://localhost:4243/blocks` | `cd web && PORT=4243 npx tsx mock/server.ts > /tmp/mock-server.log 2>&1 &` |
| Vite dev | `curl -sS http://localhost:5173/` | `cd web && npx vite > /tmp/vite.log 2>&1 &` |

## Steps

### 1 — Resolve which agent(s) to test

`$ARGUMENTS` is `claude`, `codex`, or `both` (default both). Map to script IDs `claude-3` and/or `codex-3`.

### 2 — Preflight

Run all checks in parallel via Bash. Stop and report if any **required** prereq fails. Auto-start the optional components.

```bash
pgrep -fl AskMac >/dev/null || echo "MISSING: AskMac"
test -S "$HOME/.ask/sockets/claude-3.sock" || echo "MISSING: claude-3 socket"
test -S "$HOME/.ask/sockets/codex-3.sock"  || echo "MISSING: codex-3 socket"
curl -fsS http://localhost:4243/blocks > /dev/null || echo "START: mock server"
curl -fsS http://localhost:5173/        > /dev/null || echo "START: vite"
```

If `START: mock server` appears, run `cd /Users/kevin/Documents/code/ask/web && PORT=4243 npx tsx mock/server.ts > /tmp/mock-server.log 2>&1 &` and wait until `curl http://localhost:4243/blocks` returns 200.

If `START: vite` appears, run `cd /Users/kevin/Documents/code/ask/web && npx vite > /tmp/vite.log 2>&1 &` and poll until `curl http://localhost:5173/` returns 200.

### 3 — Pick a target session per agent

Read the daemon's session registry and pick a session in `state` `idle`, `awaiting_user`, or `running_tool` (skip `stopped`, `starting`). Prefer sessions with a populated `tty` or `tmux_target` so the test can verify the actual terminal received the message.

```bash
python3 - <<'PY'
import json, os
for agent, path in [
    ('claude-3', os.path.expanduser('~/.ask/claude3-sessions.json')),
    ('codex-3',  os.path.expanduser('~/.ask/codex3-sessions.json')),
]:
    try:
        sessions = json.load(open(path))
    except Exception:
        print(f'{agent}: NO SESSIONS')
        continue
    for sid, s in sessions.items():
        state = s.get('state', '?')
        if state in ('stopped', 'starting'):
            continue
        print(f'{agent}\t{sid}\t{state}\ttty={s.get("tty","")}\ttmux={s.get("tmux_target","")}\tcwd={s.get("cwd","")}')
PY
```

**If no usable sessions exist for an agent**, mark that agent as `SKIPPED — no live sessions` and continue. Do NOT auto-launch a session — that opens a Terminal window the user didn't ask for.

⚠️ **Never target the Claude Code session that this skill is running in** — it's the parent process. Filter out any claude-3 session whose `raw_id` matches `$CLAUDE_SESSION_ID` (the env var the agent is running under), or — if that's not available — whose `tty` is empty AND `tmux_target` is empty (the in-process supervisor session has no routing). Prefer claude-3 sessions with a real `tty` or `tmux_target`.

### 4 — Snapshot the daemon log offset

For each agent under test, record the current size of its log so we can read just the new lines later:

```bash
CLAUDE_OFFSET=$(wc -c < ~/.ask/logs/claude-3.log 2>/dev/null || echo 0)
CODEX_OFFSET=$(wc -c <  ~/.ask/logs/codex-3.log  2>/dev/null || echo 0)
```

### 5 — Inject the test message

Generate a unique probe string per session so we can grep for it cleanly:

```
PROBE="ask-validate-$(date +%s)-${RANDOM}"
```

Send via the **mock server's HTTP endpoint** (this is the same path the iPhone/web UI uses). The skill should NOT call the daemon socket directly — the point is to test the full chain that the user sees.

The mock server resolves the block by `blockID` and looks up its `scriptID` and `session_id` from the payload. The block ID is `<agent>-session-<suffix>`, where `<suffix>` is the **full** segment after the colon in `session_id`:

```bash
SUFFIX="${SESSION_ID##*:}"            # e.g. "104cb45519" (claude/codex both use full suffix)
# claude-3:  block id = claude3-session-${SUFFIX}
# codex-3:   block id = codex3-session-${SUFFIX}
BLOCK_ID="${AGENT_PREFIX}-session-${SUFFIX}"

curl -sS -X POST "http://localhost:4243/respond/${BLOCK_ID}" \
  -H 'Content-Type: application/json' \
  -d "{\"value\":\"${PROBE}\"}"
```

If the block is **not currently in `~/.ask/blocks.json`** (which happens when the daemon hasn't re-emitted the session block yet, or AskMac dropped it on TTL), the mock server's `/respond/<blockID>` endpoint will fall through to its `clearBlock` default. In that case **fall back to direct socket** as a covered failure mode, and report it as a UI-path gap:

```bash
python3 - <<PY
import socket, json
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(os.path.expanduser('~/.ask/sockets/${AGENT}.sock'))
sock.sendall(json.dumps({'type':'ui_respond','session_id':'${SESSION_ID}','value':'${PROBE}'}).encode())
sock.shutdown(socket.SHUT_WR)
print(sock.recv(4096).decode())
PY
```

### 6 — Verify the daemon routed the message

Read the daemon log starting from the offset captured in step 4 and grep for the probe and routing markers:

```bash
tail -c +$((CLAUDE_OFFSET+1)) ~/.ask/logs/claude-3.log | grep -E "${PROBE}|ui_respond|inject_tty|send_text"
```

**PASS criteria for routing:**
- A line matching `socket event type='ui_respond'` for the target session
- A line containing `reply session=...` with `ok=True`

If both are present, the message reached the daemon and was routed. If routing failed (`ok=False`), report the routing error and stop.

### 7 — Verify the agent received the message (tmux only)

For sessions with `tmux_target`, capture the pane and look for the probe text:

```bash
tmux capture-pane -t "${TMUX_TARGET}" -p | grep -F "${PROBE}"
```

For tty-only sessions (claude-3 plain-terminal): there's no portable way to read the terminal's scrollback. Skip this check and note "agent-receive verification skipped (no tmux)".

### 8 — Wait for the hook round-trip

Poll the daemon log (every 1s, up to 8s) for a fresh `user_prompt_submit` event with a session_id that matches the target session's `raw_id`. This is the agent calling its own hook to acknowledge the typed message:

```bash
for i in $(seq 1 8); do
  if tail -c +$((OFFSET+1)) ~/.ask/logs/${AGENT}.log | grep -q "user_prompt_submit.*${RAW_ID:0:11}"; then
    echo "HOOK FIRED"
    break
  fi
  sleep 1
done
```

**PASS criteria for round-trip:** the hook fires within 8s. **WARN if delayed** (>4s) — agent is alive but slow. **FAIL** if no hook fires within 8s — the message was injected but the agent didn't see it (terminal disconnected, agent crashed, or tmux pane is in a non-input state like a scroll buffer).

### 9 — Verify the block updates in blocks.json

After the hook fires, the daemon should call `_emit_session_block` again with the new `last_prompt`/`first_prompt`. Read `~/.ask/blocks.json` and confirm the agent_session block's payload now contains the probe:

```bash
python3 - <<PY
import json, os
data = json.load(open(os.path.expanduser('~/.ask/blocks.json')))
for b in data.get('blocks', []):
    if b['blockID'] == '${BLOCK_ID}':
        payload = json.loads(b['payload'])
        print('last_prompt:', payload.get('last_prompt',''))
        print('preview:    ', payload.get('preview',''))
        break
else:
    print('BLOCK NOT FOUND')
PY
```

**PASS criteria for UI update:** `last_prompt` or `preview` contains `${PROBE}`. If `BLOCK NOT FOUND`, the daemon emitted but AskMac didn't persist the block to disk — flag this as a separate problem.

### 10 — Report

Print a single table summarising each tested agent:

```
Agent      Session                         Routing  Tmux-recv  Hook-back  Block-updated
claude-3   claude3:582bdb8a25 (no tty)     PASS     SKIP       PASS       PASS
codex-3    codex3:104cb45519 (codex:skills)PASS     PASS       PASS (1s)  PASS
```

Then a one-line verdict: `✅ All agents healthy.` or `❌ codex-3 hook timed out — see ~/.ask/logs/codex-3.log:NNN`.

If anything failed, link to the relevant log file with the byte offset that was captured at step 4 so the user can `tail -c +OFFSET file | less` themselves.

## Common failure modes and what they mean

| Symptom | Likely cause | Where to look |
|---|---|---|
| `MISSING: claude-3 socket` after AskMac is up | Daemon crashed on startup | `~/.ask/logs/claude-3.log` head |
| Routing PASS, hook-back FAIL | tmux pane is in scroll/copy mode, or agent crashed | `tmux capture-pane -t ... -p` for the agent's prompt |
| Routing PASS, tmux-recv FAIL | `inject_tty`/`send_text` returned ok but text never arrived — terminal-manager-agent mismatch | `~/.ask/logs/terminal-manager.log` |
| Hook-back PASS, block-updated FAIL | Daemon emitted but AskMac dropped the block | AskMac console (Xcode) for `emit_block` errors |
| `BLOCK NOT FOUND` from the start | Daemon hasn't re-emitted since restart — `_emit_session_block` dedup gating may be skipping a re-emit | Restart the script via the AskMac reload button |

## Notes on self-sufficiency

- This skill **does not require an AskMac restart** — daemons reload via the Settings → Actions ↺ button, which Claude can suggest but the user must click. After deployment via `/deploy-scripts`, run this skill instead of asking the user to reinstall.
- The skill **does not require the iPhone** — it exercises the same `/respond/<blockID>` HTTP endpoint that the iPhone hits via CloudKit + the web bridge. If this skill passes, the iPhone path passes too (assuming iPhone↔CloudKit auth is healthy, which is a separate concern).
- The skill **must NOT target its own session** — see the warning in step 3.
