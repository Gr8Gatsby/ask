# Dev Design: Terminal Mirror

Implementation plan for the feature defined in `terminal-mirror.md` (v0.2).

## Architecture overview

```
tmux pane
   │  (every 5s)
   ▼
claude-3 daemon          ── poll capture-pane -p, diff vs last frame
   │                        ↳ emit "terminal_mirror" messages
   ▼
AskMac DaemonHost        ── ingests via append_message JSON-RPC
   │
   ▼
TaskFeed (CloudKit)      ── messages with role="terminal" (new role)
   │
   ├──► iPhone           ── render inline in chat, monospace, dimmer; 1-week local cache
   └──► AskMac           ── render inline in session detail (parity), same treatment
```

## Daemon side (claude-3)

### Capture loop

A new asyncio task per tmux-routed session, started on session register / migrate-to-tmux, cancelled on session_stop or pane-gone:

```python
async def _mirror_loop(self, session: SessionRecord):
    """Sample tmux pane every 5s, emit diff as messages.

    Cancelled when session moves to stopped or when pane reports gone.
    """
    last_frame_lines: list[str] = []
    while session.state != 'stopped' and session.tmux_target:
        try:
            frame = await self._capture_pane(session.tmux_target)
        except Exception as exc:
            _log(f'mirror capture failed for {session.session_id}: {exc!r}', 'WARN')
            await asyncio.sleep(MIRROR_INTERVAL_SECS)
            continue
        new_lines = self._diff_frame(last_frame_lines, frame)
        if new_lines:
            await self._emit_terminal_mirror(session, '\n'.join(new_lines))
            last_frame_lines = frame
        await asyncio.sleep(MIRROR_INTERVAL_SECS)
```

- `_capture_pane(target)` calls `tmux capture-pane -t <target> -p -S -200` via the terminal-manager. `-S -200` includes last 200 lines of scrollback so we don't miss anything during a 5s window of fast output. `-p` prints to stdout.
- `_diff_frame(old, new)` is "the suffix of `new` not present at the end of `old`." Specifically: find the longest suffix of `old` that is a prefix of `new`, return `new` minus that overlap. This handles the common case where part of `old`'s tail is still visible in `new` after scrolling.
- Mirror is **opt-in by default for tmux sessions** (matches "should just work" expectation) but can be disabled via `mirror_enabled` field on the session record. The disable toggle is set by an iPhone/Mac UI action that calls a new daemon RPC `set_mirror_enabled`.
- A small ring of last-emitted hashes prevents accidental duplicate emits across daemon restarts (last_frame_lines persists in session registry JSON).

### Emit format

Reuse the existing `append_message` channel, with a new role `terminal`:

```python
await self.append_message(session.task_id, 'terminal', text)
```

Constants in `claude-3/main.py`:

```python
MIRROR_INTERVAL_SECS = 5
MIRROR_MAX_CHUNK_BYTES = 20_000   # split chunks larger than this
```

If `len(text) > MIRROR_MAX_CHUNK_BYTES`, split on line boundaries and emit each piece as its own message.

### Session lifecycle hooks

- `_handle_session_start` (or first `_handle_pre_tool_use` with tmux_target) → spawn `_mirror_loop` task and store on `session.mirror_task`.
- `_handle_session_stop` (turn end, stays idle) → loop keeps running.
- Eviction / pane gone / session stopped → `session.mirror_task.cancel()`.

### Backpressure / failure

- The 5s sleep absorbs slow capture: a 4s capture still gives 1s before the next tick.
- If `append_message` raises (CloudKit upload failed), log + drop that chunk. Update `last_frame_lines` anyway so we don't re-emit the same content next tick (avoids amplification).

## AskMac side

### TaskFeed message role

Add `terminal` to the message role enum in the model and TaskFeed render. Treatment:

- Monospace font
- Slightly dimmer foreground (0.7 alpha equivalent)
- No avatar / label header
- "Show more" collapse after 12 lines

### CloudKit retention

Adjust the FeedSchedule cleanup pass to apply a shorter TTL to `role=terminal` messages. Specific TTL: 24h server-side. Local cache keeps them indefinitely (next bullet).

### Client-side cache

Both iPhone and Mac currently rehydrate from the local task-feed cache. The cache prune already keeps messages up to ~1 week. Confirm `role=terminal` messages aren't pruned more aggressively than that and are retained even after the matching CloudKit record disappears.

Mark cached-only messages with a subtle treatment (e.g. trailing "·" or italicized timestamp).

### Disable toggle UI

- Session detail → top-right menu → "Mirror terminal" checkbox.
- Calls a new daemon RPC `set_mirror_enabled(session_id, enabled)` which:
  - Persists `mirror_enabled` on the session record
  - Cancels `mirror_task` if disabling; spawns it if re-enabling
- Default: enabled for new tmux sessions.

## Rollout

1. **Daemon-only behind a feature flag** — `ASK_MIRROR=1` env var to enable. Land in claude-3 v0.5.0, verify capture + diff + emit in dev. Flag default off.
2. **AskMac UI for the new role + disable toggle** — land in next AskMac release.
3. **iPhone UI for the new role** — land in next iOS release.
4. **Flip flag default on** in claude-3 v0.5.1 once all three clients render.

## Testing

- Unit-ish: `_diff_frame` with crafted before/after frames covering overlap, scroll-past-window, identical frames.
- Stress: run a noisy script (e.g. `for i in {1..1000}; do echo $i; done`) in a mirrored tmux session and confirm chunk splitting works.
- Manual: run `/validate-messaging` against a tmux session with mirror on; verify mirror messages appear in `/blocks` payload.

## Open implementation questions

1. Should `terminal` messages count toward "last_message" in the session block? **Lean no** — last_message should remain the assistant's latest spoken response, not terminal noise.
2. Where to persist `mirror_enabled`? Same session registry JSON or new file? **Lean same file** since it's per-session.
3. iOS render: does the existing message renderer support per-role styling, or do we need to plumb a styling field through? **Need to check** before estimating client work.

## Change log

| Date | Change |
|---|---|
| 2026-05-14 | v0.2 — daemon side landed behind `ASK_MIRROR=1`. claude-3 0.5.0 (mirror loop + `_diff_frame` + lifecycle wiring), terminal-manager 2.2.2 (new `capture_pane` tool). 5 unit tests for `_diff_frame` cover identity, append, scroll, no-overlap, empty-old. AskMac + iPhone UI is next. |
| 2026-05-14 | v0.1 — initial dev design, ready for implementation. |
