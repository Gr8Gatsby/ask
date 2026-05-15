# Feature: Terminal Mirror for tmux-routed agent sessions

## Problem

When supervising a Claude Code session on iPhone, users see the agent_session block (current task, working state) but the chat surface itself is mostly empty between assistant turns. Tool calls, build output, file diffs, and other terminal activity that scrolls in the user's terminal pane never reaches the iPhone. Long stretches of "blank screen" undercut confidence that anything is actually happening.

## Goals

1. The iPhone chat for a tmux-routed agent session shows what's actually happening in the terminal, not only the assistant-message snapshots from the Stop hook.
2. A user returning to a session later sees the same history a witness would have seen — terminal activity is persisted, not just live.
3. Reading the chat on a phone-sized screen stays comfortable: chunked, skimmable, not a wall of escape codes.
4. The feature does not degrade other sessions or block the daemon on slow tmux captures.
5. The user can opt out per session if they want a quieter feed.

## Non-goals (v1)

- A faithful terminal emulator with cursor positioning, ANSI color, and live scrollback re-render. (Future v2 — see "Open questions".)
- Replaying the entire pre-existing scrollback when a session is first opened on iPhone. v1 mirrors only from the moment the feature begins capturing.
- Mirroring non-tmux sessions (raw TTY sessions are out of scope for v1 because we cannot reliably capture them without a PTY interceptor).

## User-facing behavior

### iPhone

- **Existing chat surface remains.** Assistant messages (from Stop hook) continue to render as today. Terminal activity appears in the same scrollable feed, visually distinct (e.g. monospace, dimmer treatment) so the user can tell what came from Claude vs. what scrolled in the terminal.
- **Newest at bottom**, time-ordered with existing messages.
- **No flicker / no redraws**: each terminal chunk appears once and stays. The chat does not retroactively rewrite earlier chunks.
- **Tap to expand**: long chunks are collapsed to N lines with a "show more" affordance.
- **Per-session toggle** in the session settings to disable terminal mirroring for that session (off → behavior is unchanged from today).

### Mac

- AskMac's session detail view shows the same mirrored terminal feed inline with the chat, with the same visual treatment as iPhone (monospace, dimmer). Parity matters: a screenshot from either client should show the same conversation history.

## What gets captured

- For each tmux-routed claude-3 session with mirroring enabled, the daemon samples the pane's scrollback every 5 seconds while the session is active and emits the **new lines since the last sample** to the session's message feed.
- "Active" means the session is in the registry and its tmux pane is alive. Polling continues at the same cadence regardless of state — a stalled prompt that shows nothing new simply emits nothing.
- Identical, repeated frames produce no emit (de-duplication so a static prompt line doesn't spam the feed).
- If the pane reports gone (tmux returns no such target), capture for that session stops and the session ends normally.

## Boundaries and privacy

- The user is the operator of both ends. Terminal output may contain paths, environment variables, and tokens — the user explicitly wants those visible (they may need them). No redaction in v1.
- Mirrored content lives in the same CloudKit private container as existing chat messages.
- The user can disable mirroring per session (see above).

## Reliability

- Capture failures (tmux not responding, pane gone) must not crash the daemon and must not block other sessions.
- If a chunk is too large for a single CloudKit message, it is split into multiple chunks rather than dropped.
- If CloudKit upload fails, the daemon logs and drops that chunk. The next successful 5s tick re-establishes the live stream from that point forward.

## Retention

- **Server-side (CloudKit):** mirror messages are short-lived. Specific TTL TBD but materially shorter than assistant messages (e.g. 24h vs. session lifetime).
- **Client-side cache (iPhone, Mac):** ~1 week. The clients keep the messages locally even after they age out of CloudKit so opening an older session still shows what happened.
- When a mirror message exists only in the local cache, the UI marks it (e.g. a subtle "from cache" treatment) so the user knows it's no longer cloud-backed.

## Open questions (deferred to v2)

- **Live terminal tab.** A second view that renders the actual tmux pane with ANSI colors and a live cursor, polled faster than 5s. The chat tab and terminal tab would share the same underlying capture. Revisit after v1 ships.
- **Quiet hours / battery.** Whether to slow the 5s cadence when no client has been observed reading recently. Out of scope for v1.

## Change log

| Date | Change |
|---|---|
| 2026-05-14 | v0.2 — incorporated user decisions: no redaction (operator owns both ends), Mac renders mirror inline for parity, server retention short with ~1 week client cache, 5s cadence while session active. |
| 2026-05-14 | v0.1 — initial draft, awaiting user review. |
