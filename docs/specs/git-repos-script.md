# Git Repos Script — Functional Specification

## Overview

Replaces the GitHub issues script. Scans the user's Mac for local git repositories,
surfaces those with unpushed commits or uncommitted changes, and lets the user push,
pull, fetch, or discard changes directly from their iPhone.

---

## Requirements

### Discovery

- On startup and every 5 minutes, scan the entire home directory (`~`) for local git
  repositories by locating `.git` directories
- Directories known to contain non-repo noise are excluded from traversal:
  `node_modules`, `Library`, `.Trash`, `Pods`, `DerivedData`, `.build`, `build`,
  `dist`, `vendor`, `venv`, `.venv`, `.cache`, `.npm`, `.yarn`, `__pycache__`, `target`
- Hidden directories (starting with `.`) are skipped except `.git` itself
- Maximum of 100 repositories are tracked per scan
- Repos with no commits yet are skipped

### Per-repo state

For each discovered repository the script determines:
- Current branch name
- Remote tracking branch (if any)
- Number of commits ahead of remote (unpushed)
- Number of commits behind remote (not yet pulled)
- Whether the working tree has uncommitted changes, and how many files are affected

### Tile (home screen)

Shows a summary line:
- "N repos need attention" (orange) when any repo has unpushed commits or uncommitted changes
- "All repos up to date" (green) when everything is clean
- "No repos found" if the scan returns nothing

### Repository list (iPhone)

Repos are listed in priority order:
1. Repos with unpushed commits — shown first
2. Repos with uncommitted changes
3. Repos behind remote
4. Clean repos

Each row shows the repo name, current branch, and a short state label:
`↑2 to push`, `↓1 to pull`, `3 changed`, `up to date` (combined as needed, e.g.
`↑1 to push · 2 changed`).

A **Refresh** action at the bottom of the list triggers an immediate re-scan.

### Detail view (tapping a repo)

Shows:
- Repo name (title)
- Branch, remote tracking branch (or "no remote"), ahead count, behind count,
  uncommitted file count — formatted as readable prose

Action buttons shown based on state:
- **Push** — shown only when ahead > 0 and a tracking branch exists
- **Pull** — shown only when behind > 0 and a tracking branch exists
- **Fetch** — always shown when a remote is configured
- **Discard Changes** — shown only when dirty

### Push

`git push` runs on the Mac against the configured tracking remote. On success, the
repo state refreshes and the detail view updates to reflect the new state.

### Pull

`git pull` runs on the Mac. On success, repo state refreshes and the detail view updates.

### Fetch

`git fetch` runs on the Mac. On success, repo state refreshes and the detail view updates.

### Discard Changes

Requires a confirmation block before executing. The confirmation shows how many files
will be discarded and warns that the action cannot be undone. On confirm, `git restore .`
runs on the Mac.

### Operation feedback

While any git operation is running, a status block shows "Pushing…" / "Pulling…" /
"Fetching…" / "Discarding…". On completion:
- Success: brief "Done" status (green, auto-clears after 2 s)
- Failure: error message from git shown in status block (red, auto-clears after 5 s)

After every operation the tile and list both update to reflect the new repo states.

### No remote

Repos with no remote configured are included in the list with state label "local only"
and no Push / Pull / Fetch actions.

---

## Non-Goals

- Creating or deleting branches
- Resolving merge conflicts
- Staging individual files
- Viewing diff or commit history
- Configuring remotes from iPhone

---

## Change Log

| Date | Change |
|---|---|
| 2026-03-31 | Initial spec — replaces GitHub issues script |
