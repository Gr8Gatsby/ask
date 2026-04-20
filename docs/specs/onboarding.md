# Onboarding — Functional Spec

First-time user experience for AskMac. Goal: get a new user from a fresh install to seeing a script respond in under two minutes, with no configuration required.

---

## Overview

The onboarding flow has three acts:

1. **Install & launch** — pkg installer, auto-launch, system permissions
2. **Welcome** — orient the user, one CTA that installs Hello World directly
3. **Live demo** — see Hello World respond in the popover

No account required. No iPhone required. No configuration required.

---

## Act 0 — Install & System Permissions

The `.pkg` installer auto-launches AskMac on completion. Before the Welcome screen appears, AskMac requests the minimum permissions it needs to function. These are shown in a single pre-permissions screen so the user knows what's coming before the macOS dialogs fire.

```
┌─────────────────────────────────────────────┐
│                                             │
│              ◉  Ask needs access            │
│                                             │
│   Ask requires a couple of permissions     │
│   to run scripts and alert you.            │
│                                             │
│   ┌─────────────────────────────────────┐  │
│   │ 🔔  Notifications                   │  │
│   │     Show blocks when popover        │  │
│   │     is closed                       │  │
│   └─────────────────────────────────────┘  │
│                                             │
│   ┌─────────────────────────────────────┐  │
│   │ 🔄  Login Item                      │  │
│   │     Start automatically when        │  │
│   │     you log in                      │  │
│   └─────────────────────────────────────┘  │
│                                             │
│           [ Continue → ]                   │
│                                             │
└─────────────────────────────────────────────┘
```

**Behavior:**
- These are the only two permissions required at install time — for Hello World and the core app to work
- "Continue →" triggers the macOS Notifications and Login Item permission dialogs in sequence
- Additional permissions (AppleScript, home folder access, etc.) are requested later, only when the user installs a script that declares them in its manifest
- If the user denies Notifications: the app still works but blocks only appear when the popover is open; a persistent warning is shown in Settings
- If the user denies Login Item: the app still works but must be launched manually after reboot; a reminder is shown in Settings

---

## Act 1 — Welcome Screen

Shown once on first launch. Triggered when no scripts have ever been installed.

```
┌─────────────────────────────────────────────┐
│                                             │
│                                             │
│              ◉  Ask                         │
│                                             │
│      Remote control your Mac               │
│      with your iPhone.                     │
│                                             │
│      You can create custom scripts         │
│      with AI to do almost anything.        │
│                                             │
│      ──────────────────────────             │
│                                             │
│         [ Install Hello World! ]           │
│                                             │
│                                             │
└─────────────────────────────────────────────┘
```

**Behavior:**
- Appears as a standard window (not the popover), centered on screen
- "Install Hello World!" skips directly to installing the hello-world script — no intermediate catalog step
- After install completes the window closes and focus moves to the popover (Act 3)
- No "Skip" or "Later"
- The Script Catalog is accessible anytime from menu bar → "Add Scripts…" for users who want to explore further

---

## Act 2 — Script Catalog

Accessible from menu bar → "Add Scripts…" at any time after onboarding. The catalog is fetched from the GitHub `scripts-latest` release (`catalog.json`).

Two sections: scripts whose prerequisites are detected on this Mac shown first, then the full catalog below.

```
┌─────────────────────────────────────────────┐
│  Add Scripts                           [×]  │
├─────────────────────────────────────────────┤
│                                             │
│  Works on your Mac                          │
│  ─────────────────────────────────────      │
│  ┌─────────────────────────────────────┐    │
│  │ 🍺  Brew Monitor                    │    │
│  │     Get notified when Homebrew      │    │
│  │     packages are outdated           │    │
│  │     Needs: shell                    │    │
│  │                      [ Install ]    │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │ ⚡  Claude Code                     │    │
│  │     Approve tool calls from your    │    │
│  │     iPhone while Claude Code runs   │    │
│  │     Needs: home_directory, shell    │    │
│  │                      [ Install ]    │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  All Scripts                                │
│  ─────────────────────────────────────      │
│  ┌─────────────────────────────────────┐    │
│  │ 🐙  GitHub                          │    │
│  │     Surface PR reviews and CI       │    │
│  │     failures                        │    │
│  │     Needs: home_directory, shell,   │    │
│  │           network                   │    │
│  │                      [ Install ]    │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │ 🦙  Ollama                          │    │
│  │     Monitor and update local        │    │
│  │     Ollama models                   │    │
│  │     Needs: shell, network           │    │
│  │                      [ Install ]    │    │
│  └─────────────────────────────────────┘    │
│                                             │
└─────────────────────────────────────────────┘
```

If no prerequisites are detected (clean Mac), "Works on your Mac" shows:

```
│  Works on your Mac                          │
│  ─────────────────────────────────────      │
│                                             │
│      Make a script!                        │
│                                             │
```

*(Make a script flow is out of scope for this spec.)*

**Behavior:**
- Catalog fetches on open; spinner while loading, error + retry if fetch fails
- "Works on your Mac" shows up to 5 scripts whose prerequisites are detected, sorted alphabetically; already-installed scripts are excluded
- "All Scripts" shows everything else from the catalog, alphabetically; already-installed scripts show "Installed ✓" instead of Install
- Each card shows the permissions declared in the script's manifest under "Needs:"
- "Install" downloads the script zip, extracts to `~/.ask/scripts/<id>/`, and registers it with the daemon
- If the script declares permissions AskMac hasn't been granted yet, the macOS permission dialog fires immediately after tapping Install — before the script starts
- After install the button changes to "Installed ✓" and the script starts immediately

---

## Act 3 — Hello World Running

After tapping "Install Hello World!" the welcome window closes, the menu bar icon animates (bounces), and the popover springs open from the icon. Hello World's confirmation block is already showing.

```
  ┌─ AskMac ─────────────────────────────┐
  │                                      │
  │  👋  Hello World                     │
  │  ─────────────────────────────────   │
  │                                      │
  │   ╔═══════════════════════════════╗  │
  │   ║  Hello, World! 👋             ║  │
  │   ║                               ║  │
  │   ║  Greetings from your Ask      ║  │
  │   ║  script. What would you       ║  │
  │   ║  like to do?                  ║  │
  │   ║                               ║  │
  │   ║  [ Say it back ]  [ Dismiss ] ║  │
  │   ╚═══════════════════════════════╝  │
  │                                      │
  └──────────────────────────────────────┘
```

User taps **"Say it back"** or **"Dismiss"** — either response triggers the completion nudge:

```
  ┌─ AskMac ─────────────────────────────┐
  │                                      │
  │  👋  Hello World                     │
  │  ─────────────────────────────────   │
  │                                      │
  │   ╔═══════════════════════════════╗  │
  │   ║  ● Hello back at ya! 👋       ║  │
  │   ╚═══════════════════════════════╝  │
  │                                      │
  │  ─────────────────────────────────   │
  │                                      │
  │   ✦  Add or make more scripts!      │
  │      [ Add Scripts ]  [ Make One ]  │
  │                                      │
  └──────────────────────────────────────┘
```

**Behavior:**
- Menu bar icon bounces to draw the user's eye, then the popover animates open from the icon
- The confirmation block is showing before the animation completes
- After the user responds, the "Add or make more scripts!" nudge appears below the Hello World section
- "Add Scripts" opens the Script Catalog
- "Make One" is a placeholder — out of scope for this release, links to docs for now
- The nudge persists until dismissed or the user installs another script
- If "Say it back" was chosen, the "Hello back at ya!" status block shows above the nudge for 30 seconds as normal, then clears

---

## What the User Has Learned

By the end of Act 3, without reading any docs, the user understands:

- Scripts run persistently in the background
- They surface blocks (cards) in the AskMac popover
- You respond by tapping a button
- More scripts are available in the catalog

---

## Script Permission Contract

Scripts declare required permissions in `manifest.json`. AskMac enforces this at install time and at runtime.

### Manifest declaration

```json
{
  "id": "github",
  "name": "GitHub",
  "version": "1.0",
  "description": "Surface PR reviews and CI failures",
  "entry": "main.py",
  "icon": "ant.circle",
  "permissions": ["home_directory", "shell"]
}
```

### Permission vocabulary

| Token | What it grants | Example scripts |
|---|---|---|
| `notifications` | Post macOS notifications | (all scripts, built-in) |
| `shell` | Run shell commands via subprocess | brew-monitor, github |
| `home_directory` | Read access to `~/` | github, claude-3 |
| `applescript` | Execute osascript to query apps | terminal-manager |
| `network` | Outbound HTTP beyond CloudKit/MCP | ollama, github |

### Runtime enforcement

- AskMac tracks which permissions each installed script has been granted
- If a script attempts to use a permission it did not declare, AskMac:
  1. Logs the violation with script ID, permission name, and timestamp
  2. Posts a macOS notification: *"[Script Name] tried to use [permission] — not declared in its manifest"*
  3. Emits a persistent warning block in the popover (orange, with script name and what was attempted)
  4. Does **not** kill the script — the script may recover with a fallback path
- Grants are per-script — one script's grant does not extend to others
- If the user later revokes a permission in System Settings, AskMac detects this and emits a warning block for the affected script

---

## Edge Cases

| Situation | Behavior |
|---|---|
| No internet on first launch | Catalog shows error + retry button; Welcome screen still visible |
| No dependencies | Hello World is a zero-dependency bash script — no additional checks needed |
| User closes welcome window before installing | Welcome window gone — catalog accessible via menu bar → "Add Scripts…" |
| User dismisses Hello World without saying it back | Normal — script re-greets immediately after response |

---

## Out of Scope

- iOS app setup (separate flow, accessed from menu bar → "Set up iPhone…")
- Script configuration screens (per-script, post-install)
- Script removal during onboarding
- Accounts or sign-in

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-19 | Initial spec |
| 2026-04-19 | Added Act 0 (install & system permissions), script permission contract, manifest vocabulary, runtime enforcement |
| 2026-04-19 | Updated Welcome copy and CTA; catalog split into "Works on your Mac" + "All Scripts" sections |
| 2026-04-19 | Act 3: menu bar icon bounce + popover animation; post-response "Add or make more scripts!" nudge |
| 2026-04-19 | Act 2 catalog: "Works on your Mac" section using requires checks from manifest; permissions field added to CatalogEntry; release-scripts skill updated to include permissions + requires in catalog.json |
| 2026-04-19 | PermissionRow layout: button moved inside VStack to prevent subtitle truncation; notification row deep-links to AskMac's notification settings page |
| 2026-04-19 | Dev build isolation: replaced #if DEBUG with runtime isDevBuild checks; dev vault moved to ~/.ask/dev-vault to avoid TCC prompts on ~/Documents access |
| 2026-04-19 | Bash scripts (hello-world, brew-monitor, github, ollama): fix reader_loop stdin inheritance (`<&0`) for non-interactive bash; hello-world re-greets immediately after each response (removed sleep); versions bumped |
