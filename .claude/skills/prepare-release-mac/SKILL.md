---
name: prepare-release-mac
description: Prepare a Mac (AskMac) release — version bump, release notes, spec changelog, commit. Run before /release-mac.
---

Prepare the next AskMac desktop release. Follow every step in order. Do not skip steps or ask the user to do things manually — do the work yourself using tools.

## Step 1 — Verify repo state

Run `git status` and `git branch --show-current`. If the working tree is not clean or the branch is not `main`, stop and tell the user to fix that first.

## Step 2 — Find the last Mac release

Run: `git tag --sort=-version:refname | grep '^v' | head -1`

If no tag exists, treat the beginning of history as the starting point.

## Step 3 — List commits since the last release

Run: `git log {LAST_TAG}..HEAD --oneline`

Group the commits by type prefix (feat, fix, perf, chore, refactor, docs). Show the user the grouped list. Note which platforms the commits touch (Mac, iOS, scripts, shared).

## Step 4 — Propose a version bump

Read the current `MARKETING_VERSION` from `AskMac/project.yml`.

Apply semantic versioning:
- **patch** — only fix/perf/chore commits
- **minor** — at least one feat commit, no breaking changes
- **major** — breaking change indicated in commit message

Propose the new version with a one-sentence justification. Ask the user to confirm or override. Wait for confirmation before continuing.

## Step 5 — Write release notes

Write release notes with two sections:

**Section 1 — Prose summary (2–4 sentences)**
Write naturally, as if describing the release to a user who hasn't read the commits. Focus on what changed from the user's perspective, not implementation details. Do not just restate commit messages.

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
AskMac v1.2.0

This release delivers the PKG installer with per-script opt-in installation
and integrates Sparkle for automatic background updates. Script update
detection now surfaces a one-tap banner in the menu bar when newer versions
are bundled with an app update.

### What's New
- feat(distribution): PKG installer with optional script components (a46052d)
- feat(sparkle): Sparkle 2.x auto-update integration (b3f91c2)

### Bug Fixes
- fix(notifications): cold-start navigation and subscription reliability (335aadc)

### Performance
- perf(polling): reduce idle interval 30s→5s (e2c5ec4)
```

Present the draft to the user. Ask them to review and suggest any edits. Incorporate any feedback. Confirm with the user before proceeding.

## Step 6 — Bump the Mac version

Edit `AskMac/project.yml`: update the `MARKETING_VERSION` value to the confirmed version.

Verify the edit with a read.

## Step 7 — Update the spec changelog

Open `docs/spec.md` and add a new row at the top of the Change Log table:

```
| {today's date} | Mac v{version}: {one-line summary of the release} |
```

Keep it to one line. Use today's date in `YYYY-MM-DD` format.

## Step 8 — Create a release branch and commit

Create a branch and commit the version bump:

```bash
git checkout -b release/mac-{version}
```

Stage only the files changed:
- `AskMac/project.yml`
- `docs/spec.md`

Commit with message: `chore(mac): bump version to {version}`

## Step 9 — Open a PR

Push the branch and open a PR targeting `main`:

```bash
git push -u origin release/mac-{version}
gh pr create --title "chore(mac): release v{version}" --head release/mac-{version} --base main --body "..."
```

The PR body should include:
- A one-sentence summary of the release
- A "Test plan" checklist:
  - [ ] Merge PR
  - [ ] Run `/release-mac` to tag v{version}
  - [ ] Run `/build-pkg-mac` to build and publish artifacts

Return to `main` after pushing:
```bash
git checkout main
git reset --hard origin/main
```

## Step 10 — Output release notes

Print the final release notes to the conversation — they will be used as the tag annotation when the user runs `/release-mac` after merging.
