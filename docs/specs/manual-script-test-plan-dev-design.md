# Manual Script Test Plan — Dev Design

**Companion to:** `docs/specs/manual-script-test-plan.md`
**Status:** in progress
**Branch:** `fix/session-persistence` (continuing the dashboard line)

## Approach

Layer plans **on top** of the existing run storage. Do not migrate or rip out
the current slideshow. Two principles:

- **Backward compatible:** every existing run keeps its current path
  (`web/.review/runs/<id>/story/<spec>/...`). Old `feedback.json` and
  `review.json` continue to work. A run without a `planId` is filed under a
  synthetic "Legacy runs" plan so the new IA still renders it.
- **Additive routes:** `#/run/<id>` continues to work as today. New routes
  (`#/`, `#/plan/<id>`, `#/plan/<id>/run/<id>`, `#/plan/<id>/run/<id>/<case-id>`)
  are added alongside.

## Phases

| Phase | What ships |
|---|---|
| 1 (this PR) | Plan model, seed plan JSON, plan/run/case API routes, plans index, plan detail, run detail (case rollup), case slideshow (breadcrumb only), legacy `#/run/<id>` redirect, `tested{}` snapshot, one working hello-world web case |
| 2 | Per-script Playwright specs for the rest of the catalog |
| 3 | Computer-use driver for AskMac surface; AskMac cases per script |
| 4 | Reporting polish: sparklines, diff vs. last run, open-issues panel |
| 5 | Subset-run UI, plan editor UI |

## Data model

### Plan file: `web/review-plans/<id>.json`

(Plans are source artifacts and live in git. Runs stay under
`web/.review/runs/` which remains gitignored.)

```json
{
  "id": "manual-script-sweep",
  "title": "Manual script sweep",
  "version": "1.0.0",
  "description": "Per-script regression: web + AskMac.",
  "cases": [
    {
      "id": "hello-world-web",
      "scriptId": "hello-world",
      "surface": "web",
      "title": "Hello World · Web",
      "spec": "scripts/hello-world.web.spec.ts",
      "deps": [],
      "status": "implemented"
    },
    {
      "id": "hello-world-mac",
      "scriptId": "hello-world",
      "surface": "askmac",
      "title": "Hello World · AskMac",
      "driver": "computer-use",
      "deps": [],
      "status": "pending"
    }
  ]
}
```

`status` is `implemented | pending | skipped`. Pending cases render as
greyed-out rows in the plan detail view; they don't run.

### Run schema (extended)

```ts
interface Run {
  id: string
  planId: string | null         // NEW; null = legacy
  planVersion: string | null    // NEW
  scope: 'all' | { caseIds: string[] }   // NEW; defaults to 'all' for legacy
  tested: TestedSnapshot | null // NEW
  spec: string
  startedAt: number
  endedAt: number | null
  exitCode: number | null
  screenshotCount: number
  status: 'running' | 'awaiting-review' | 'reviewed'
  review: Review | null
  gitHead: string | null
  caseResults?: CaseResult[]    // NEW; computed at run end
}

interface TestedSnapshot {
  git: { head: string; shortHead: string; branch: string; dirty: boolean }
  askmac?: { version: string; source: string }
  scripts: Array<{ id: string; version: string; enabled: boolean }>
  vault: 'dev' | 'prod' | 'unknown'
}

interface CaseResult {
  caseId: string
  status: 'passed' | 'failed' | 'skipped' | 'pending'
  storyPath: string | null      // existing per-spec story dir
  stepCount: number
  feedback: { kind: string; count: number }[]
  decision: 'approved' | 'changes-requested' | 'rejected' | null
}
```

Per-case decisions live in `feedback.json` companions
(`runs/<id>/cases/<caseId>/review.json`) for new runs. Legacy runs keep
their flat `runs/<id>/review.json`.

### Storage layout (new + legacy side by side)

```
web/
  review-plans/                             ← NEW: source-controlled plans
    manual-script-sweep.json
  .review/                                  ← gitignored (run output)
    runs.json                               ← unchanged (run index)
  runs/
    <run-id>/
      meta.json                             ← NEW: planId, planVersion, scope, tested
      output.txt
      ── new-style (planId set):
      cases/
        <case-id>/
          story.json
          NN-*.png + NN-*.html
          feedback.json                     ← scoped to one case
          review.json                       ← case-level decision
      ── legacy (planId null):
      story/<spec>/...                      ← unchanged
      feedback.json                         ← unchanged
      review.json                           ← unchanged
```

The story recorder writes into whichever layout the runner declares. The
review-server reads both and synthesizes a uniform `caseResults[]` for the
UI.

## API surface

| Method | Route | Purpose |
|---|---|---|
| GET | `/api/plans` | All plans |
| GET | `/api/plans/:id` | One plan |
| GET | `/api/plans/:id/runs` | Runs for a plan, newest first |
| POST | `/api/plans/:id/runs` | Start a new run; body: `{ scope: 'all' \| { caseIds: [...] } }` |
| GET | `/api/runs/:id` | Run detail (existing — extended with caseResults) |
| GET | `/api/runs/:id/cases/:caseId` | Case slice (story + feedback + review) |
| POST | `/api/runs/:id/cases/:caseId/review` | Case-level decision |
| GET | `/api/tested-snapshot` | Capture current `tested{}` block (used at run start) |

Existing `/api/runs/:id/feedback` keeps its path; for new-style runs it now
takes a `caseId` query param to scope to a case.

## Routes (UI)

| Hash | Render |
|---|---|
| `#/` | Plans index |
| `#/plan/:id` | Plan detail |
| `#/plan/:id/run/:runId` | Run detail with case rollup |
| `#/plan/:id/run/:runId/:caseId` | Case slideshow (existing per-step UI) |
| `#/run/:id` | Backward compat — redirect to plan/run if `planId` set, else render in legacy mode |

## Phase 1 cut-list

In scope for this PR:

1. Add types + storage helpers for plans
2. Seed `web/review-plans/manual-script-sweep.json` with every script as a
   case (most `pending`, hello-world web as `implemented`)
3. Implement `/api/plans*` routes
4. Capture `tested{}` snapshot at run start
5. Plans-index UI replaces today's runs-table at `#/`
6. Plan-detail UI: cases table + run history table
7. Run-detail UI: case rollup (uses existing slideshow for case drill-in)
8. Legacy `#/run/<id>` route stays, with a banner when the run has a planId
9. One hello-world web spec wired through the new runner
10. Functional spec changelog updated; this dev design committed

Out of scope until later phases:

- Sparklines, diff-vs-last, open-issues panel
- Subset-run UI (Phase 1 always runs the plan's `implemented` cases)
- Computer-use AskMac walkthroughs
- Plan editor UI

## Risks

- **Slideshow regressions** — the slideshow code is freshly stable from the
  pin/HTML-toggle work. We add a `caseId` query for new-style runs but
  otherwise leave it untouched.
- **Storage migration** — none. New runs use the new layout, old runs read
  unchanged. No batch moves.
- **Computer-use scope creep** — explicitly punted to Phase 3.

## Test plan for this PR

- Plans index renders with one plan.
- Plan detail shows the seed cases; pending cases are visible and not runnable.
- Starting a run from plan detail produces a new run id, captures `tested{}`,
  invokes the hello-world spec, and writes to `cases/hello-world-web/`.
- Run detail shows the case rollup; clicking the case opens the slideshow
  with pins/HTML toggle working.
- Legacy `#/run/<id>` for a pre-plan run still renders the old slideshow.
- Lint clean (`npm run lint` in `web/`).

## Change log

| Date | Note |
|---|---|
| 2026-05-03 | Initial dev design for Phase 1 foundation |
| 2026-05-03 | Phase 1 implementation landed: plan + case + run-meta types, /api/plans*, plans index / plan detail / run rollup / case slideshow scoping, story recorder caseId support, hello-world web spec (one implemented case) |
| 2026-05-03 | Phase 2: startRun accepts specs[]; shared `_walkthrough.ts` helper; 9 new per-script web specs land (brew-monitor, github, ollama, gdocs-history, web-traffic, task-demo, terminal-snapshot, claude-3, codex-3); plan now reports 10/20 implemented |
