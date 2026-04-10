# Functional Spec: Persistent Chat History

**Status:** Draft — Pending Review
**Date:** April 10, 2026

---

## Overview

Chat history in the iOS app is currently ephemeral and session-scoped. Each new Claude Code or Codex session starts with a blank slate, messages are lost when the app is not actively displaying the chat view, and a temporary network disconnection can cause the view to dismiss and messages to be missed. This spec describes a persistent, repo-scoped chat history that survives session restarts, app backgrounding, and reconnections.

---

## Goals

- Show the full conversation history for a repo across all sessions, not just the current one.
- Capture messages reliably regardless of which screen is visible or whether the app is foregrounded.
- Never dismiss the chat view due to a temporary disconnection.
- Give the user control over their history via a Settings screen.

---

## Non-Goals

- Syncing history across multiple iOS devices (history is local to the device).
- Exporting or searching history.
- Storing tool activity groups or confirmation blocks in long-term history (these are session-ephemeral by nature).

---

## History Identity

Each conversation thread is identified by a **history key** composed of:

```
machineID / scriptID / project
```

Where `project` is the repo path as reported by the script (e.g. `code/ask`). Sessions on the same repo, machine, and script share one continuous history thread regardless of how many times the session has been restarted.

---

## Requirements

### 1. Persistent history storage

- All assistant messages and user messages are stored persistently on-device (SwiftData, no CloudKit sync).
- History is stored per history key, not per session ID.
- History is retained indefinitely until the user explicitly clears it.
- A session boundary marker is inserted into the thread whenever a new session ID is observed for an existing history key. The marker includes the date and time the new session started.
- The first session for a given history key does not show a boundary marker — just the messages.

### 2. App-level message capture

- Message capture is not dependent on the chat view being visible.
- The app captures each new `lastMessage` value for every live session block as soon as it arrives from CloudKit, even if the user is on the home screen, in Settings, or the app is in the background (subject to iOS background refresh limits).
- If a message arrives while the chat view is open, it is captured once — not duplicated.
- If a message arrives while the chat view is closed, it is written directly to the history store and appears when the user opens the view.

### 3. Chat view shows full history

- When the user opens a session chat, they see all history for that history key — all prior sessions and the current session — in chronological order, newest at the bottom.
- The view scrolls to the bottom on open.
- Session boundary markers appear inline between sessions as subtle date/time labels.
- Confirmation blocks (permission requests, option pickers) appear inline in history at the time they occurred, showing the option the user chose. These are not replayed as active prompts in old sessions.
- Activity groups (tool use summaries) appear inline at the time they occurred.

### 4. Chat view does not dismiss on disconnection

- If the session block temporarily disappears from CloudKit (Mac daemon restart, network blip), the chat view stays open.
- A reconnecting indicator is shown in the navigation bar subtitle. No additional banner is shown.
- "Session ended" is only inserted into the history when the session block has been absent for more than 15 seconds. A transient blip shorter than 15 seconds produces no event in the history.
- The user navigates away from the chat view using the back button only — never by an automatic dismissal.
- When the session block reappears (same or new session ID on the same history key), the view resumes normally. If a new session ID appears, a session boundary marker is inserted and new messages continue appending.

### 5. User message history

- Messages the user sends are stored in history at the time they are sent.
- Send status (sending, sent, delivered, failed) is shown transiently while the view is open, not persisted.

### 6. Settings — Chat History

A "Chat History" section appears in the iOS app's Settings screen with the following:

- A list of all history keys that have stored messages, showing:
  - The project name (last path component of the project string)
  - The machine name
  - The script name
  - The date of the most recent message
  - The total message count
- Tapping a history key shows the full message history for that project (read-only, non-interactive).
- Each history key row has a swipe-to-delete action that clears all messages for that project.
- A "Clear All Chat History" button at the bottom of the section clears all stored history after a confirmation prompt.

### 7. New session inherits history

- When a new session starts for a repo that already has history, the existing history is visible immediately when the user opens the chat — no action required.
- The session boundary marker is the only visual indication that a new session has started.

---

## Changelog

| Date | Change |
|------|--------|
| 2026-04-10 | Initial draft |
