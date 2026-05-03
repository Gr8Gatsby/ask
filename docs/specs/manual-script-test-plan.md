# Manual Script Test Plan — Functional Spec

**Status:** DRAFT — awaiting review
**Owner:** Kevin
**Last updated:** 2026-05-03

## 1. Purpose

Provide a structured, repeatable manual-test pass that isolates **one script at a
time** and exercises it through both surfaces (the iPhone webview at
`localhost:5173` and the native AskMac app). The pass produces step-by-step
screenshots that are reviewed in the existing localhost review dashboard, where
issues can be pinned with comments (UI/UX, layout, performance) for triage.

The dashboard is reorganized so **test plans are the entry point**. Every run
belongs to a plan, every case in a run rolls up to that plan's coverage view,
and every pin is anchored to a specific git head and tested-version snapshot.

This is an **enhancement to** today's manual testing — it does not replace
exploratory testing or release smoke tests. It adds a deterministic, per-script
walkthrough that always covers the same surfaces in the same order, plus
plan-level reporting to spot regressions across runs.

## 2. Goals

- Per-script regression coverage that catches UI/UX, layout, and performance regressions
- Single source of evidence: every issue is anchored to a step screenshot with a pin
- Dependency-aware isolation so script-on-script interactions do not muddy results
- Parity check: every script is exercised on **both** the web surface and AskMac
- Plan-first reporting: coverage, run history, and trend lines per plan
- Reproducibility: every run captures the git head, branch, dirty flag, AskMac
  build, iOS build, and active script versions
- Low-friction execution: one command should drive a full per-plan or
  per-case pass
- Multi-plan support from day one, with a single launch plan; subset-runs
  (any selection of cases within a plan) are a first-class operation
- Native AskMac walkthroughs are automated through computer-use so they
  produce the same per-step artifacts as web walkthroughs

## 3. Scope

### 3.1 In scope (scripts under test)

Tile / feed / utility scripts that present a UI:

| Script | Surfaces | Hard dependencies |
|---|---|---|
| hello-world | web feed/tile | — |
| brew-monitor | web feed | brew installed |
| github | web feed/tile | git repos under `~` |
| ollama | web feed | ollama installed |
| gdocs-history | web feed | Safari/Chrome history |
| web-traffic | web feed | browser history |
| task-demo | web feed | — |
| terminal-snapshot | web tile | **terminal-manager** |
| claude-3 | web feed + chat | **terminal-manager** |
| codex-3 | web feed + chat | **terminal-manager**, tmux, codex CLI |
| claudecode-controller | web tile | claude-3 |
| opencode-controller | web tile | (TBD — design only today) |

System scripts exercised only as dependencies, not directly under test:

- terminal-manager (system, headless registry — verified through dependents)

### 3.2 Out of scope

- Push-notification delivery to a real iPhone (covered by `/validate-messaging`)
- CloudKit sync correctness on real hardware (covered by paused iOS-vs-web project)
- Onboarding / install flow (covered by release smoke tests)
- Performance benchmarking with numeric SLAs — this pass surfaces *visible* perf
  issues only (jank, slow first paint, spinner stuck, etc.)

## 4. Test environment requirements

- Web app reachable at `http://localhost:5173`
- AskMac running locally (launched from Xcode for dev vault) and reachable at
  `http://localhost:4242`
- Review dashboard reachable at `http://localhost:4244`
- Review dashboard supports plans, cases, runs, pins, and reporting (this spec)
- A clean script vault state: each pass begins with **all scripts disabled**
  except the script under test plus its declared dependencies

## 5. Information architecture (plan-first)

The dashboard pivots from run-centric to plan-centric. Four nested concepts:

```
Test Plan
  └─ Test Case               (one script × one surface)
       └─ Run                (one execution at a given git head)
            └─ Step          (one slide: image + HTML + pins)
```

A **Plan** owns a set of cases. A **Run** is one execution of one or more cases
under a plan, against a single git head. A **Case Result** is the per-case
slice of a run.

### 5.1 Routes

```
#/                                              Plans index — default landing
#/plan/<plan-id>                                Plan detail — scope, cases, run history
#/plan/<plan-id>/run/<run-id>                   Run detail — per-case rollup
#/plan/<plan-id>/run/<run-id>/<case-id>         Case slideshow — today's per-step UI
#/run/<run-id>                                  Legacy redirect to the new path
```

### 5.2 Reporting layers

**Layer 1 — Plans index (the new home)**

A table of every plan with: title, # cases, last run timestamp, last-run pass
rate, last-run decision, drift status (any source files changed since last
approval).

**Layer 2 — Plan detail**

- Plan metadata (title, description, version, scope summary)
- **Coverage table** — every declared case, last result, last decision, and a
  sparkline of the last N runs so regressions are visible at a glance
- **Run history table** — every run with git context, tested versions, tally,
  and decision; click to drill in
- **Open issues** — every unresolved `bug` / `confusing` pin in the most
  recent run, grouped by case

**Layer 3 — Run detail**

- Header strip: plan @ version, `git.shortHead` + branch + dirty marker,
  AskMac vN, iOS vN, started/ended, scope (`all` or `case:<id>`)
- **Diff vs. last run on this plan** — cases that regressed (passed → failed
  or new bug pins) highlighted
- **Per-case rollup table:** case, status (passed / failed / skipped /
  pending), step count, pin counts split by kind, case-level decision, link
  to the slideshow
- **Run output** (collapsed `<details>`)

**Layer 4 — Case slideshow** — the per-step UI we have today, breadcrumbed
back to its plan and run.

### 5.3 Decision rollup

Per-case decisions are authored in the case slideshow (approve /
changes-requested / rejected, with optional summary). The run's decision is
**computed** from its cases:

- All cases approved → run `approved`
- Any case rejected → run `rejected`
- Otherwise → run `changes-requested`

A plan does not itself carry a decision — its reporting reflects the rollup of
its most recent run.

## 6. Test isolation model

For each case in a run, the pass shall:

1. Disable every other script in the vault
2. Enable the case's script and any scripts it declares as dependencies
3. Wait for the vault to settle (manifests reloaded, hooks installed)
4. Run the per-case walkthrough on the declared surface (web or AskMac)
5. Restore the prior vault state when the case ends (or on abort)

Dependency map used by isolation:

- `claude-3 → terminal-manager`
- `codex-3 → terminal-manager`
- `terminal-snapshot → terminal-manager`
- `claudecode-controller → claude-3 → terminal-manager`
- `opencode-controller → (per its manifest, when published)`

## 7. Per-case walkthrough — common steps

Every case's walkthrough must capture the following steps (extra script-specific
steps are added on top). Each step produces a screenshot **plus** the captured
HTML (web only) so issues can be pinned and shipped to a coding agent.

### 7.1 Web surface (iPhone webview)

1. **Cold open** — feed view with the script just installed
2. **Tile/feed entry** rendered for the script
3. **Tap into detail** — primary script surface opens
4. **Empty state** — what the user sees with no data yet
5. **Populated state** — script with realistic data
6. **Primary action** — the most-used action runs end-to-end
7. **Error / refused state** — denied permission, missing dependency, or offline
8. **Back-out** — return to the feed; verify the feed reflects the new state

### 7.2 AskMac surface

1. **Cold open** — Settings ▸ Scripts shows the script enabled
2. **Script row** — version, manifest summary, enable/disable toggle
3. **Permissions sheet** — the script's declared permissions are listed
4. **Block view** (if the script publishes blocks) — block renders correctly
5. **Logs / errors pane** — recent log lines, no red errors
6. **Disable / re-enable** — verify the script tears down and re-installs cleanly

### 7.3 Script-specific extensions

Each case appends its own steps. Examples (non-exhaustive):

- **claude-3** — start a new session, send a message, see the reply, see the
  permission prompt round-trip
- **codex-3** — open existing tmux session, send a message, see scrollback
- **brew-monitor** — show outdated list, run "upgrade" from feed, see status update
- **github** — list repos, run pull/push, see commit feedback
- **ollama** — show model list, surface available update
- **gdocs-history** — list of recently viewed docs, group by source
- **web-traffic** — list visits, switch browser source, group by day
- **terminal-snapshot** — pick a pane, capture text, capture image, verify both

## 8. Plans as authored artifacts

Plans are authored as files in source control under
`web/review-plans/<plan-id>.json`. A plan declares its cases without requiring
each spec to be implemented up-front; cases without an implementation render in
the dashboard as `pending` so missing coverage is reportable.

Each plan record carries:

- `id`, `title`, `description`, `version`
- `cases[]` — each case has `id`, `scriptId`, `surface` (`web` | `askmac`),
  `spec` (path to the Playwright spec) or `driver` (for non-Playwright
  walkthroughs), and declared `deps`

The narrative spec (this document) and the plan JSON file stay in sync via
the change-log rule. The plan JSON is the executable contract; this document
is the human-readable rationale.

## 9. Reproducibility — what every run captures

Every run record shall include a `tested` snapshot:

- **Git context:** head sha, short sha, branch name, dirty flag, summary of
  changed files since the previous run on the same plan
- **AskMac:** version, source (Xcode dev build / `/Applications` / DMG)
- **iOS:** version, target (simulator / device), if any iOS step exists in the run
- **Scripts:** every active script's id and version at run start
- **Vault:** dev or prod

This snapshot is shown on the run-detail header and used for staleness
detection on plan and case views.

## 10. Issue capture model

For every step screenshot, the reviewer can attach one or more **pins**. Pins
already support these kinds:

- `bug` — functional defect
- `style` — visual / theming issue
- `copy` — text content or wording
- `confusing` — UX / IA problem
- `slow` — observed performance issue
- `ok` / `comment` — confirmations and freeform notes

Each pin shall include:

- A natural-fraction (x, y) location on the image
- Free-text description
- A "Copy step context" hand-off that bundles step title, description, all
  comments, and the captured HTML for paste into a coding-agent chat

Pin counts roll up to the case (per kind), to the run (per kind), and to the
plan's last run (per kind, in the open-issues panel). Issues are not
auto-filed to GitHub; the reviewer decides which pins escalate.

## 11. Acceptance criteria

A **case pass** is complete when:

- All required common steps captured (web or AskMac, per the case's surface)
- All script-specific steps captured
- Every step screenshot is present and readable in the case slideshow
- The case is browseable at `#/plan/<plan-id>/run/<run-id>/<case-id>`

A **case pass is clean** when:

- Zero pins of kind `bug` or `confusing`
- All `slow` pins triaged with a follow-up note
- A case-level decision of `approved` is recorded

A **run is complete** when every selected case in the run has a case pass.
A **run is clean** when its computed decision is `approved`.

A **plan is current** when its latest run is clean and not flagged as drifted
(no source-tree changes under `web/src/` or `ask/scripts/` since approval).

## 12. Cadence

- **Pre-release** — full plan run before each Mac and iOS release
- **Per-feature** — single-case run for any script touched in a PR
- **Ad hoc** — anytime a UI/UX regression is suspected

## 13. Decisions and open questions

**Decided 2026-05-03:**

- **Multiple plans, start with one.** The IA is built to host any number of
  plans from day one. We launch with a single plan (`manual-script-sweep`)
  and add more (release smoke, markdown render, send-message round-trip) as
  needed. The dashboard must support running an arbitrary subset of cases
  within a plan — full sweeps are not always required.
- **AskMac driver is computer-use automation.** AskMac walkthroughs are
  driven by the `mcp__computer-use__*` tools so they are repeatable and
  produce the same per-step screenshots as the web walkthroughs. Manual
  hand-driven uploads are not the default path.

**Still open:**

1. **claudecode-controller** — the directory exists but has no source. Is
   this feature still active, or should it be removed from scope?
2. **opencode-controller** — design-only today. Skip it, or declare it as a
   `pending` case so the coverage gap is visible?
3. **task-demo** — currently auto-runs on install. Should the case treat
   that as the populated state, or trigger a manual run?
4. **Dependency teardown** — when a dependency is enabled solely for a
   case, disable it again at the end, or leave it enabled?
5. **iOS surface** — when the paused iOS-vs-web comparison resumes, do iOS
   cases live in this same plan or a sibling plan?

## 14. Change log

| Date | Note |
|---|---|
| 2026-05-03 | Initial draft for review |
| 2026-05-03 | Plan-first IA, four-layer reporting, expanded run reproducibility snapshot |
| 2026-05-03 | Decided: launch with one plan but support many; cases can be subset-run; AskMac driven by computer-use automation |
| 2026-05-03 | Phase 1 shipped: plan model, /api/plans*, plans index, plan detail, run rollup, case slideshow scoping, hello-world web case wired through new runner |
| 2026-05-03 | Phase 2 shipped: multi-spec runner; all 10 web cases implemented (hello-world, brew-monitor, github, ollama, gdocs-history, web-traffic, task-demo, terminal-snapshot, claude-3, codex-3) via a shared 8-step walkthrough helper |
