---
name: validate-messaging
description: End-to-end test that messages from the iPhone/web app reach a live Claude Code or Codex tmux/terminal session and that responses flow back. Lets Claude self-verify the supervisor pipeline without asking the user to reinstall AskMac.
argument-hint: [claude|codex|both] [--stress=N]  (default: both, no stress)
---

Validates the **iPhone → CloudKit → AskMac → daemon → terminal-manager → tmux/tty → agent → hook → AskMac → iPhone** messaging round-trip on the dev box, end to end. Use this whenever you've changed claude-3, codex-3, terminal-manager, or any of the hooks and want to confirm the round trip still works.

## What this tests

```
[test driver]                                                          [agent]
     │                                                                    ▲
     ▼                                                                    │
 AskMac /respond ──→ daemon socket ──→ inject_tty/send_text ──→ tty/tmux ─┘
     ▲                                                                    │
     │                                                                    ▼
 AskMac /blocks ◀── emit_block ◀── _handle_user_prompt ◀── hook fires ◀───┘
```

The test exercises the same HTTP endpoints that the iPhone hits via CloudKit and that the web app hits via the vite proxy. If a message goes in via the test driver and a fresh hook event lands in the daemon log within a few seconds, the round trip is healthy.

## When to use vs. NOT use

**Use when:**
- You changed code in `ask/scripts/claude-3/`, `ask/scripts/codex-3/`, the hooks, or `terminal-manager`
- A user reports a session disappearing, messages not arriving, or hook events not firing
- You want to confirm a fix before pushing

**Do NOT use when:**
- You only changed the web/iOS UI (no daemon changes) — run `npm run dev` and inspect manually
- The user is mid-session in the target tmux pane — the test injects a visible message into their terminal

## Backend selection

The skill calls a single backend that exposes `/blocks` and `/respond/<blockID>`. There are two:

| Port | Backend | When |
|---|---|---|
| **4242** | AskMac LocalHTTPServer (real, in DEBUG builds) | AskMac is running from Xcode — preferred |
| **4243** | Mock server (`web/mock/server.ts`) | AskMac is not running — fallback |

⚠️ The mock server reads `~/.ask/blocks.json`, which **AskMac does not currently write to** — so the mock server's view of `agent_session` blocks is stale. Always prefer port 4242 when AskMac is up. The skill picks 4242 if it answers, else 4243, else fails the preflight.

## Prerequisites

| Component | Check | If missing |
|---|---|---|
| AskMac (Xcode build) | `pgrep -fl AskMac` | Tell the user to launch from Xcode |
| claude-3 daemon | `test -S ~/.ask/sockets/claude-3.sock` | Reload scripts in AskMac (↺ in Settings → Actions) |
| codex-3 daemon | `test -S ~/.ask/sockets/codex-3.sock` | Same |
| Backend on 4242 OR 4243 | `curl -fsS http://localhost:4242/blocks` then 4243 | If AskMac is running on 4242, you're done. Otherwise start the mock server (see below). |

## Steps

### 1 — Resolve which agent(s) to test

`$ARGUMENTS` is `claude`, `codex`, or `both` (default both). Map to script IDs `claude-3` and/or `codex-3`.

### 2 — Preflight

```bash
pgrep -fl AskMac >/dev/null || echo "MISSING: AskMac"
test -S "$HOME/.ask/sockets/claude-3.sock" || echo "MISSING: claude-3 socket"
test -S "$HOME/.ask/sockets/codex-3.sock"  || echo "MISSING: codex-3 socket"

# Pick a backend
if curl -fsS http://localhost:4242/blocks > /dev/null 2>&1; then
  BACKEND=http://localhost:4242
  echo "BACKEND: AskMac (4242)"
elif curl -fsS http://localhost:4243/blocks > /dev/null 2>&1; then
  BACKEND=http://localhost:4243
  echo "BACKEND: mock (4243) — agent_session blocks may be stale"
else
  # Try to start mock as last resort
  cd /Users/kevin/Documents/code/ask/web && PORT=4243 npx tsx mock/server.ts > /tmp/mock-server.log 2>&1 &
  sleep 2
  curl -fsS http://localhost:4243/blocks > /dev/null && BACKEND=http://localhost:4243 \
    && echo "BACKEND: mock (4243) — started" \
    || echo "MISSING: no backend on 4242 or 4243"
fi
```

Stop and report if any **required** prereq fails.

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

### 4 — Verify the agent_session block exists in the backend

The backend's `/blocks` is the single source of truth that the iPhone/web UI sees. If the agent_session block isn't there, the user can't message the session through the UI even though the daemon registry says it's alive.

```bash
SUFFIX="${SESSION_ID##*:}"            # e.g. "104cb45519" — full segment after the colon
BLOCK_ID="${AGENT_PREFIX}-session-${SUFFIX}"   # claude3-session-... or codex3-session-...

curl -fsS "${BACKEND}/blocks" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ids = [b['blockID'] for b in data.get('blocks', [])]
print('present' if '${BLOCK_ID}' in ids else 'MISSING — UI cannot show this session')
"
```

If MISSING, mark the agent as `UI-PATH FAIL` but keep going via socket fallback so we still know if routing itself works.

### 5 — Snapshot the daemon log offset

Record the current size of the daemon's log so we can read just the new lines later:

```bash
OFFSET=$(wc -c < ~/.ask/logs/${AGENT}.log 2>/dev/null || echo 0)
```

### 6 — Inject the test message via the backend (UI path)

```
PROBE="ask-validate-$(date +%s)-${RANDOM}"
```

```bash
curl -sS -X POST "${BACKEND}/respond/${BLOCK_ID}" \
  -H 'Content-Type: application/json' \
  -d "{\"value\":\"${PROBE}\"}"
```

Expected response: `{"ok":true}`. If the response is anything else, the backend rejected the request — read the response body for the reason.

If the agent_session block was MISSING in step 4, the backend can't resolve `scriptID` from `blockID` and will fail. Fall back to direct socket so we can still validate the daemon-and-down portion:

```bash
python3 - <<PY
import socket, json, os
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(5)
sock.connect(os.path.expanduser('~/.ask/sockets/${AGENT}.sock'))
sock.sendall(json.dumps({'type':'ui_respond','session_id':'${SESSION_ID}','value':'${PROBE}'}).encode())
sock.shutdown(socket.SHUT_WR)
print(sock.recv(4096).decode())
PY
```

### 7 — Verify the daemon routed the message

Read the daemon log starting from the offset captured in step 5:

```bash
tail -c +$((OFFSET+1)) ~/.ask/logs/${AGENT}.log | grep -E "${PROBE}|ui_respond|block response|inject_tty|send_text|reply session"
```

**PASS criteria:** a `reply session=...` line with `ok=True` for the target session, plus an entry-point line:
- `socket event type='ui_respond'` (via mock-server `/respond` → daemon socket), OR
- `block response block_id='...'` (via AskMac MCP `notifications/message` from `/respond` on port 4242)

The two paths come in through different doors but both must produce `reply session=... ok=True` to count as routed.

### 8 — Verify the agent received the message (tmux only)

For sessions with `tmux_target`:

```bash
tmux capture-pane -t "${TMUX_TARGET}" -p | grep -F "${PROBE}"
```

For tty-only sessions (claude-3 plain-terminal): there's no portable way to read the terminal's scrollback. Skip and note "agent-receive verification skipped (no tmux)".

### 9 — Wait for the hook round-trip

Poll the daemon log (every 1s, up to 8s) for a fresh `user_prompt_submit` event:

```bash
for i in $(seq 1 8); do
  if tail -c +$((OFFSET+1)) ~/.ask/logs/${AGENT}.log | grep -q "user_prompt_submit"; then
    echo "HOOK FIRED ($i s)"
    break
  fi
  sleep 1
done
```

**PASS:** hook fires within 8s. **WARN if delayed** (>4s). **FAIL** if no hook fires within 8s — the message was injected but the agent didn't see it (terminal disconnected, agent crashed, or tmux pane is in a non-input state like a scroll buffer).

### 10 — (Advisory) Verify the block payload briefly reflected the probe

This check is racy: after `_handle_block_response` sets `preview = probe`, the agent's `session_idle` hook fires shortly after and clears `preview = ''`. So this check **must run immediately after step 7** (routing PASS), before step 9. If the agent is fast, the probe will already be gone by the time you re-fetch.

Treat this as **advisory**: if it's `updated`, great. If it's `NOT updated` but routing + hook-back both passed, do not fail the run — log it as a warning and move on.

```bash
# Run RIGHT AFTER step 7 (do not sleep)
curl -fsS "${BACKEND}/blocks" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for b in data.get('blocks', []):
    if b['blockID'] == '${BLOCK_ID}':
        payload = json.loads(b.get('payload','{}'))
        text = (payload.get('last_prompt') or '') + (payload.get('preview') or '')
        print('updated' if '${PROBE}' in text else 'NOT updated (likely already cleared by session_idle)')
        break
else:
    print('block disappeared from backend')
"
```

### 11 — Report

Print a single table summarising each tested agent:

```
Agent      Session                              Block-in-UI  Routing  Tmux-recv  Hook-back  Block-flash
claude-3   claude3:582bdb8a25 (no tty)          PASS         PASS     SKIP       PASS (1s)  WARN (cleared)
codex-3    codex3:104cb45519 (codex:skills.0)   PASS         PASS     PASS       PASS (1s)  PASS
```

**Pass criteria for the overall run:** Routing + Hook-back both PASS for every tested agent. Block-flash is advisory — `WARN` is acceptable. Block-in-UI is required for messaging through the UI to work, but the run can still pass with `FAIL` if you fell back to the socket and the rest of the chain works (this signals "daemon side is fine, but a separate UI-emit bug exists").

Then a one-line verdict: `✅ All agents healthy.` or `❌ codex-3 hook timed out — see ~/.ask/logs/codex-3.log @ offset NNN`.

## Stress mode (`--stress=N`)

When the user includes `--stress=N` in `$ARGUMENTS` (default N is omitted = single run), repeat steps 5–9 N times against the same session, with a short sleep between iterations, and report flake rate. Skip step 10 (it's already advisory).

```python
N = int(<arg>)            # e.g. 20
results = []              # list of {routing, tmux_recv, hook_back_secs}
for i in range(N):
    PROBE = f"stress-{i}-{int(time.time())}-{random.randint(1000,9999)}"
    offset = os.path.getsize(LOG)
    requests.post(f"{BACKEND}/respond/{BLOCK_ID}", json={"value": PROBE})
    time.sleep(1)
    new = open(LOG, 'rb').read()[offset:].decode(errors='replace')
    routing = ('reply session=' in new and 'ok=True' in new)
    tmux_ok = (PROBE in subprocess.run(['tmux','capture-pane','-t',TMUX_TARGET,'-p'],
                                       capture_output=True, text=True).stdout)
    hook_t = None
    for s in range(8):
        time.sleep(1)
        new = open(LOG, 'rb').read()[offset:].decode(errors='replace')
        if 'user_prompt_submit' in new:
            hook_t = s + 1
            break
    results.append({'routing': routing, 'tmux_recv': tmux_ok, 'hook_back_secs': hook_t})
    time.sleep(3)   # let agent settle / go idle before the next probe

# Summary
total = len(results)
routing_ok  = sum(1 for r in results if r['routing'])
tmux_ok     = sum(1 for r in results if r['tmux_recv'])
hook_ok     = sum(1 for r in results if r['hook_back_secs'] is not None)
hook_secs   = [r['hook_back_secs'] for r in results if r['hook_back_secs'] is not None]
print(f"stress {total}× — routing {routing_ok}/{total}, tmux {tmux_ok}/{total}, "
      f"hook {hook_ok}/{total} (median {sorted(hook_secs)[len(hook_secs)//2] if hook_secs else 'n/a'}s)")
```

**Pass bar for production-grade:** `routing == N`, `tmux == N`, `hook >= 0.95 * N`, median hook latency ≤ 2s. Anything below that is a flake to investigate before claiming the path is solid.

## Common failure modes

| Symptom | Likely cause | Where to look |
|---|---|---|
| `MISSING: claude-3 socket` after AskMac is up | Daemon crashed on startup | `~/.ask/logs/claude-3.log` head |
| `Block-in-UI FAIL` for an idle session | Daemon emitted but `_emitted_payloads` cache may be hiding a re-emit; or AskMac was restarted but daemon didn't see it | Restart the script via the AskMac reload button — that drops the daemon's dedup cache |
| Routing PASS, hook-back FAIL | tmux pane is in scroll/copy mode, or agent crashed | `tmux capture-pane -t ... -p` for the agent's prompt |
| Routing PASS, tmux-recv FAIL | `inject_tty`/`send_text` returned ok but text never arrived — terminal-manager-agent mismatch | `~/.ask/logs/terminal-manager.log` |
| Hook-back PASS, block-updated FAIL | Daemon emitted but AskMac dropped the block, or 4243-mock-only run reading stale `blocks.json` | Use port 4242 (real AskMac), not 4243 (mock). |

## Notes on self-sufficiency

- The skill **does not require an AskMac restart** — daemons reload via the Settings → Actions ↺ button, which Claude can suggest but the user must click. After deployment via `/deploy-scripts`, run this skill instead of asking the user to reinstall.
- The skill **does not require the iPhone** — it exercises the same `/respond/<blockID>` HTTP endpoint that the iPhone hits via CloudKit and the web app hits via the vite `/api` proxy. If this skill passes against `:4242`, the iPhone path passes too (assuming iPhone↔CloudKit auth is healthy, which is a separate concern).
- The skill **must NOT target its own Claude Code session** — see the warning in step 3.
