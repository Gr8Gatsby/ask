---
name: prepare-release-ios
description: Prepare an iOS release — version bump, release notes, spec changelog, commit. Run before /release-ios.
---

Prepare the next iOS app release for TestFlight. Follow every step in order. Do not skip steps or ask the user to do things manually — do the work yourself using tools.

## Step 1 — Verify repo state

Run `git status` and `git branch --show-current`. If the working tree is not clean or the branch is not `main`, stop and tell the user to fix that first.

## Step 2 — Find the last iOS release

Run: `git tag --sort=-version:refname | grep '^ios-v' | head -1`

If no tag exists, treat the beginning of history as the starting point.

## Step 3 — List commits since the last release

Run: `git log {LAST_TAG}..HEAD --oneline`

Group commits by type prefix (feat, fix, perf, chore, refactor, docs). Note which ones are iOS-relevant (iOS app, CloudKit, notifications, blocks UI) vs Mac-only or scripts-only. Include all commits in the notes but call out iOS-specific ones clearly.

## Step 4 — Propose a version bump

Read the current iOS `MARKETING_VERSION`. Find it in `ask/ask.xcodeproj/project.pbxproj`:
Run: `grep 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj | head -1`

Apply semantic versioning:
- **patch** — only fix/perf/chore commits
- **minor** — at least one feat commit
- **major** — breaking change

Propose the new version with a one-sentence justification. Ask the user to confirm or override. Wait for confirmation before continuing.

## Step 5 — Write release notes

Write release notes with two sections:

**Section 1 — Prose summary (2–4 sentences)**
Write naturally for an iOS TestFlight tester. Focus on what they'll notice in the app — new screens, new behavior, fixes to existing flows. Do not mention Mac-side changes unless they directly affect the iOS experience.

**Section 2 — Details**
List commits grouped under these headings (omit empty groups):

```
### What's New
### Bug Fixes
### Performance
### Other Changes
```

Each line: `- {commit subject} ({short hash})`

Example final format:
```
iOS v2.1.0

This release improves push notification navigation so tapping a notification
while the app is closed now lands directly on the correct script block.
Block freshness is also improved — navigating from a notification now
triggers an immediate refresh so the confirmation block is visible right away.

### Bug Fixes
- fix(notifications): cold-start navigation, block freshness, subscription reliability (335aadc)

### Performance
- perf(polling): reduce idle interval 30s→5s, poll loop in ScriptDetailView (e2c5ec4)
```

Present the draft to the user. Ask them to review and suggest any edits. Incorporate feedback. Confirm before proceeding.

## Step 6 — Bump the iOS version

The iOS `MARKETING_VERSION` appears in `ask/ask.xcodeproj/project.pbxproj`. There are multiple occurrences (one per build configuration). Update all of them.

Run first to see the exact current value and context:
`grep -n 'MARKETING_VERSION' ask/ask.xcodeproj/project.pbxproj`

Use the Edit tool with `replace_all: true` to change every instance of:
`MARKETING_VERSION = {old_version};`
to:
`MARKETING_VERSION = {new_version};`

Verify with a re-read of the affected lines.

## Step 7 — Update the spec changelog

Open `docs/spec.md` and add a new row at the top of the Change Log table:

```
| {today's date} | iOS v{version}: {one-line summary of what's new in the iOS release} |
```

Use today's date in `YYYY-MM-DD` format.

## Step 8 — Commit

Stage only:
- `ask/ask.xcodeproj/project.pbxproj`
- `docs/spec.md`

Commit with message: `chore(ios): bump version to {version}`

## Step 9 — Output release notes

Print the final release notes to the conversation so the user can copy them for use as the git tag annotation when they run `/release-ios`.
