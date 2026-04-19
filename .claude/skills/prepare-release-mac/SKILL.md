---
name: prepare-release-mac
description: Prepare a Mac (AskMac) release — version bump, release notes, spec changelog, commit. Run before /release-mac.
---

Full end-to-end Mac release. One pause for release notes review — everything else runs automatically.

## Step 1 — Sync and verify repo state

```bash
git fetch origin main && git checkout main && git merge origin/main
```

Verify clean working tree (`git status`). If not clean, stop and tell the user.

## Step 2 — Find the last Mac release and list commits

```bash
git tag --sort=-version:refname | grep '^v' | head -1
git log {LAST_TAG}..HEAD --oneline
```

Group commits by type prefix (feat, fix, perf, chore). Note which platforms each touches.

## Step 3 — Propose a version bump

Read current version: `grep 'MARKETING_VERSION' AskMac/project.yml | head -1`

Apply semantic versioning (patch / minor / major). State the proposed version and justification — do not ask for confirmation, just proceed.

## Step 4 — Write release notes and PAUSE for user review

Write release notes:

**Prose summary (2–4 sentences)** — what changed from the user's perspective.

**Details:**
```
### What's New
### Bug Fixes
### Performance
### Other Changes
```
Each line: `- {commit subject} ({short hash})`

Present the draft. Say: "Review the release notes above — reply **yes** to proceed or give edits."

**Wait for explicit confirmation before continuing.**

## Step 5 — Bump version and update spec (after user approves)

Edit `AskMac/project.yml`: update `MARKETING_VERSION` to the new version.

Add changelog row to `docs/spec.md` at the top of the Change Log table:
```
| {YYYY-MM-DD} | Mac v{version}: {one-line summary} |
```

## Step 6 — Branch, commit, PR, and auto-merge

```bash
git checkout -b release/mac-{version}
git add AskMac/project.yml docs/spec.md
git commit -m "chore(mac): bump version to {version}"
git push -u origin release/mac-{version}
gh pr create --title "chore(mac): release v{version}" --base main --body "{one-line summary}"
gh pr merge --auto --merge
```

Then poll until the PR merges:
```bash
while true; do
  STATE=$(gh pr view --json state --jq '.state' 2>/dev/null)
  [[ "$STATE" == "MERGED" ]] && break
  echo "Waiting for PR CI to pass and merge... ($STATE)"
  sleep 15
done
git checkout main && git fetch origin main && git merge origin/main
```

## Step 7 — Create annotated tag

Write release notes to `/tmp/release-notes-mac.txt`, then:
```bash
git tag -a "v{version}" -F /tmp/release-notes-mac.txt
git tag -l "v{version}"
git push origin "v{version}"
```

## Step 8 — Build and publish

Run the build script (stream output, do not background):
```bash
./scripts/build-release.sh 2>&1 | tee /tmp/build-mac-{version}.log | grep -E "^==>|✅|❌|SUCCEEDED|FAILED|error:"
```

On failure, read `tail -50 /tmp/build-mac-{version}.log` and report the error. Do not proceed to staple.

## Step 9 — Trigger staple workflow

```bash
gh workflow run staple-release.yml --field tag=v{version}
```

Then poll until complete:
```bash
sleep 10
RUN_ID=$(gh run list --workflow=staple-release.yml --limit=1 --json databaseId --jq '.[0].databaseId')
while true; do
  STATUS=$(gh run view $RUN_ID --json status,conclusion --jq '[.status,.conclusion] | join("/")')
  echo "Staple workflow: $STATUS"
  [[ "$STATUS" == "completed/success" ]] && break
  [[ "$STATUS" == "completed/failure" ]] && echo "❌ Staple workflow failed — check https://github.com/Gr8Gatsby/ask/actions" && break
  sleep 20
done
```

## Step 10 — Report

```
✅ AskMac v{version} released

GitHub Release: https://github.com/Gr8Gatsby/ask/releases/tag/v{version}
appcast.xml updated — Sparkle auto-update live for all users.

Artifacts:
  AskMac-{version}.pkg            (PKG installer)
  AskMac-{version}-installer.dmg  (installer DMG)
  AskMac-{version}.dmg            (Sparkle update DMG)
```

**macOS 26 install workaround:** Users may see "Apple could not verify..." on macOS 26. Fix:
```bash
sudo installer -pkg "/Volumes/Install AskMac {version}/AskMac-{version}.pkg" -target /
# or: xattr -d com.apple.quarantine ~/Downloads/AskMac-{version}.pkg
```

## Prerequisite check (run silently before Step 8, report failures only)

```bash
command -v xcodegen || echo "MISSING: brew install xcodegen"
command -v create-dmg || echo "MISSING: brew install create-dmg"
ls sparkle/bin/sign_update 2>/dev/null || echo "MISSING: Sparkle tools"
security find-generic-password -a "$USER" -s APPLE_ID -w &>/dev/null || echo "MISSING: APPLE_ID"
security find-generic-password -a "$USER" -s APPLE_ID_PASSWORD -w &>/dev/null || echo "MISSING: APPLE_ID_PASSWORD"
security find-generic-password -a "$USER" -s APPLE_TEAM_ID -w &>/dev/null || echo "MISSING: APPLE_TEAM_ID"
security find-identity -v -p codesigning | grep -q "Developer ID Application" || echo "MISSING: Developer ID cert"
```

**Provisioning profile cert check** — use Python (shell pipelines are unreliable here):
```bash
KEYCHAIN_FP=$(security find-certificate -c "Developer ID Application" -p 2>/dev/null | openssl x509 -fingerprint -sha256 -noout 2>/dev/null | cut -d= -f2)
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile; do
  appid=$(security cms -D -i "$f" 2>/dev/null | grep -A1 'com.apple.application-identifier' | grep '<string>' | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
  [[ "$appid" != *"com.kevinhill.askmac"* ]] && continue
  uuid=$(basename "$f" .provisionprofile)
  PROFILE_FP=$(security cms -D -i "$f" 2>/dev/null | python3 -c "
import sys, plistlib, subprocess, tempfile, os
data = sys.stdin.buffer.read()
plist = plistlib.loads(data)
for cert in plist.get('DeveloperCertificates', []):
    with tempfile.NamedTemporaryFile(suffix='.der', delete=False) as tmp:
        tmp.write(bytes(cert)); tmp_path = tmp.name
    r = subprocess.run(['openssl','x509','-inform','DER','-fingerprint','-sha256','-noout','-in',tmp_path], capture_output=True, text=True)
    os.unlink(tmp_path)
    print(r.stdout.strip().split('=',1)[1])
")
  MATCH=$([[ "$PROFILE_FP" == "$KEYCHAIN_FP" ]] && echo "✓ MATCH" || echo "✗ MISMATCH")
  echo "UUID: $uuid | $MATCH"
done
```

Profile must show `✓ MATCH`. If `✗ MISMATCH`, regenerate the profile in the Developer Portal.
