# Script Permissions — Functional Spec

AskMac shows the user exactly which script is requesting which capability before it runs, and remembers the answer. Scripts that have not been granted all their declared permissions are held until the user approves.

---

## Terminology

| Term | Meaning |
|---|---|
| **Permission token** | A string declared in a script's `manifest.json` `permissions` array (e.g. `"shell"`, `"home_directory"`) |
| **Grant** | A user's approval of a specific permission token for a specific script, persisted across launches |
| **Consent sheet** | The in-app modal AskMac shows before a script's first run, listing the permissions it needs |
| **Pending consent** | State of a script that has declared permissions the user has not yet approved or denied |

---

## Permission Vocabulary

The full set of tokens AskMac recognises and their plain-English meanings:

| Token | What the script can do | Example |
|---|---|---|
| `shell` | Run shell commands on this Mac | brew, git, python |
| `home_directory` | Read files in your home folder (`~/`) | `~/.gitconfig`, SSH keys |
| `network` | Make outbound network requests beyond CloudKit | GitHub API, Ollama |
| `notifications` | Post macOS notifications | (built-in, always granted) |
| `applescript` | Control apps via AppleScript / osascript | Terminal, Mail |
| `full_disk_access` | Read files outside the home folder | System logs, other users |

`notifications` is treated as built-in and never shown in a consent sheet. Scripts with an empty `permissions` array start without a consent step.

---

## Consent Flow — New Script Install

When a script with non-empty permissions is installed (or first discovered on launch), AskMac shows a consent sheet before starting it.

```
┌─────────────────────────────────────────────────────┐
│                                                     │
│   🐙  GitHub wants to use:                          │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │ 🏠  Home Directory                          │   │
│   │     Read files in your home folder,         │   │
│   │     including ~/.gitconfig and SSH keys.    │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   ┌─────────────────────────────────────────────┐   │
│   │ ⚙️  Shell                                   │   │
│   │     Run commands on your Mac using          │   │
│   │     bash, git, and gh.                      │   │
│   └─────────────────────────────────────────────┘   │
│                                                     │
│   Scripts run as you. Ask shows what they need      │
│   but cannot sandbox them.                          │
│                                                     │
│                   [ Deny ]  [ Allow ]               │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Behavior:**
- All declared permissions are shown together — no per-permission dialogs
- "Allow" grants all declared permissions for this script and starts it immediately
- "Deny" stores the denial; the script is not started and shows status `permissionDenied`
- The caveat ("Scripts run as you…") is always shown
- The sheet is modal and belongs to the script, not the app — it does not block other scripts from running

---

## Consent Flow — Script With Denied Permissions

A script in `permissionDenied` status shows a card in the popover with a "Review" button. Tapping it re-opens the consent sheet so the user can change their answer.

---

## Consent Flow — Script Gains New Permissions After Update

If a script update adds a new permission token not previously granted, AskMac treats the script as pending consent again. It does not restart automatically. The user sees the consent sheet with only the **new** permissions highlighted; previously-granted permissions are shown as already approved.

---

## Migration — Already-Installed Scripts

Scripts installed before this feature existed have no stored grants. Silently blocking them all on first launch after an update would be disruptive.

**Strategy: auto-grant on migration, notify the user once.**

1. On first launch after the feature ships, AskMac checks every installed script.
2. Any script that was already running (or had previously run successfully) has all its declared permissions auto-granted with a `migrated` provenance tag.
3. A one-time notification banner appears in the popover:

```
┌─────────────────────────────────────────────────────┐
│  ℹ️  Script permissions                             │
│                                                     │
│  Your existing scripts have been granted the        │
│  permissions they declared. You can review or       │
│  revoke them in Settings → Scripts.                 │
│                                                     │
│                              [ Review ]  [ OK ]     │
└─────────────────────────────────────────────────────┘
```

4. "Review" opens Settings → Scripts where each script shows its granted permissions.
5. Scripts with no `permissions` array (or an empty one) are unaffected.
6. Scripts that were already disabled at migration time are **not** auto-granted — they go through the consent sheet on next enable.

---

## Settings — Reviewing and Revoking Grants

Each script in Settings → Scripts shows a "Permissions" section:

```
Permissions
  🏠 Home Directory      Granted  [ Revoke ]
  ⚙️  Shell              Granted  [ Revoke ]
```

- "Revoke" removes the grant and stops the script immediately
- The script enters `permissionDenied` status and shows a "Review" button in the popover
- Re-granting requires going through the consent sheet again

---

## Enforcement Model

This is a **transparency and consent** layer, not a sandbox. AskMac cannot technically prevent a script from accessing the filesystem or making network calls after it is launched — scripts run as the user. The permission system ensures the user knowingly approved the access before the script started.

This should be clearly communicated in the consent sheet (the caveat line) and in the Settings UI.

---

## What This Does Not Cover

- Revoking mid-run (stopping the script is the mechanism for that)
- Per-invocation permission checks (grants are per-script, not per-run)
- OS-level enforcement (macOS TCC gates Full Disk Access separately)
- Permissions for bundled system scripts (auto-granted, not shown)

---

## Changelog

| Date | Change |
|---|---|
| 2026-04-20 | Initial spec |
