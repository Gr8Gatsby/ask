/**
 * Ask · review dashboard
 *
 * Landing page: every test run, with status, decision, and a "may be stale"
 * badge when commits land between approval and now.
 *
 * Run detail:
 *   - Vertical step-by-step "story" timeline (from helpers/story.ts in the
 *     spec) with per-step quick-tag feedback (👍🐛🎨📝🤔⚠️) + optional text
 *   - Captured Playwright stdout
 *   - Review form to mark the run reviewed; submitting NEVER kicks off
 *     another run — re-runs are explicit via the New run button
 *
 * Approve / Changes-requested / Reject semantics
 *   approved          → don't re-prompt unless code changes (stale = code
 *                       under web/src or ask/scripts/ changed since this run)
 *   changes-requested → known-not-ready, dashboard ignores it for stale alerts
 *   rejected          → same as changes-requested — won't nag
 *
 * Storage (gitignored, web/.review/):
 *   runs.json                          – metadata for every run
 *   runs/<id>/output.txt               – captured stdout/stderr
 *   runs/<id>/screenshots/...          – frozen ad-hoc screenshots
 *   runs/<id>/story/<spec>/...         – frozen story dirs (from helpers/story.ts)
 *   runs/<id>/feedback.json            – per-step feedback {step,kind,text}
 *
 * Run with: cd web && npm run review   →   http://localhost:4244
 */
import http from 'http'
import fs from 'fs'
import path from 'path'
import { spawn, execSync } from 'child_process'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const WEB = path.resolve(__dirname, '..')
const REPO = path.resolve(WEB, '..')
const SHOTS = path.join(WEB, 'e2e', 'screenshots')
const STORY_ROOT = path.join(SHOTS, '__story')
const E2E = path.join(WEB, 'e2e')
const REVIEW = path.join(WEB, '.review')
const RUNS_DIR = path.join(REVIEW, 'runs')
const RUNS_JSON = path.join(REVIEW, 'runs.json')
fs.mkdirSync(RUNS_DIR, { recursive: true })

const PORT = parseInt(process.env.REVIEW_PORT ?? '4244', 10)

// ---------- types ---------------------------------------------------------
interface Review {
  summary: string
  decision: 'approved' | 'changes-requested' | 'rejected'
  reviewedAt: number
}
interface Feedback {
  storyPath: string   // relative path under runs/<id>/story/  e.g. "<test-slug>"
  stepIdx: number
  kind: string        // ok | bug | style | copy | confusing | slow | other
  text: string
  at: number
  // Optional pin location, as fractions (0..1) of the screenshot's natural
  // dimensions. Pins survive image rescaling; absent => unpinned (sidebar
  // comment as before).
  x?: number | null
  y?: number | null
}
interface Run {
  id: string
  spec: string
  startedAt: number
  endedAt: number | null
  exitCode: number | null
  screenshotCount: number
  status: 'running' | 'awaiting-review' | 'reviewed'
  review: Review | null
  gitHead: string | null    // sha at run start (for staleness detection)
  planId?: string | null    // when set, run belongs to a plan (new-style)
  planVersion?: string | null
}

// ---------- plan model (new-style, additive) ------------------------------
interface PlanStep {
  id: string                // unique within the case
  title: string
  description: string
  // Execution directives (web cases). Pending askmac cases omit these.
  nav?: string              // page.goto(<path>)
  waitMs?: number           // page.waitForTimeout(ms)
}
interface PlanCase {
  id: string
  scriptId: string
  surface: 'web' | 'askmac'
  title: string
  description?: string      // human-readable case description
  spec?: string             // Playwright spec relative to web/e2e (web cases)
  driver?: string           // e.g. "computer-use" (askmac cases)
  deps: string[]
  status: 'implemented' | 'pending' | 'skipped'
  steps?: PlanStep[]        // declared steps — source of truth for the spec
}
interface Plan {
  id: string
  title: string
  version: string
  description: string
  cases: PlanCase[]
}
interface TestedSnapshot {
  git: { head: string; shortHead: string; branch: string; dirty: boolean; summary: string }
  scripts: Array<{ id: string; version: string }>
  vault: 'dev' | 'prod' | 'unknown'
}
interface RunMeta {
  planId: string
  planVersion: string
  scope: 'all' | { caseIds: string[] }
  caseStoryMap: Record<string, string>   // caseId -> story slug (storyPath)
  tested: TestedSnapshot | null
}
interface CaseResult {
  caseId: string
  title: string
  surface: 'web' | 'askmac'
  status: 'passed' | 'failed' | 'skipped' | 'pending' | 'running'
  storyPath: string | null
  stepCount: number
  feedback: Array<{ kind: string; count: number }>
  decision: Review['decision'] | null
}

function loadRuns(): Run[] {
  try { return JSON.parse(fs.readFileSync(RUNS_JSON, 'utf-8')) as Run[] }
  catch { return [] }
}
function saveRuns(runs: Run[]) { fs.writeFileSync(RUNS_JSON, JSON.stringify(runs, null, 2)) }
function getRun(id: string): Run | undefined { return loadRuns().find(r => r.id === id) }
function updateRun(id: string, patch: Partial<Run>): Run | undefined {
  const runs = loadRuns()
  const i = runs.findIndex(r => r.id === id)
  if (i < 0) return
  runs[i] = { ...runs[i], ...patch }
  saveRuns(runs)
  return runs[i]
}
function newRunId(): string {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`
}

function git(args: string[]): string {
  try { return execSync(`git ${args.map(a => `'${a.replace(/'/g, "'\\''")}'`).join(' ')}`, { cwd: REPO, encoding: 'utf-8' }).trim() }
  catch { return '' }
}
function currentGitHead(): string | null { return git(['rev-parse', 'HEAD']) || null }

/** True if any file under web/src or ask/scripts has changed since the run's gitHead. */
function isPotentiallyStale(run: Run): boolean {
  if (!run.gitHead) return false
  if (!run.review || run.review.decision !== 'approved') return false
  const out = git(['diff', '--name-only', `${run.gitHead}..HEAD`])
  if (!out) return false
  for (const line of out.split('\n')) {
    if (line.startsWith('web/src/') || line.startsWith('ask/scripts/')) return true
  }
  return false
}

// ---------- run state -----------------------------------------------------
let currentRunId: string | null = null
let currentOutput = ''
const sseClients: http.ServerResponse[] = []
function broadcast(event: 'line' | 'done' | 'started', data: object) {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`
  for (const c of sseClients) { try { c.write(payload) } catch { /* drop */ } }
}

function listShots(dir: string): string[] {
  if (!fs.existsSync(dir)) return []
  const out: string[] = []
  ;(function walk(d: string) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) walk(p)
      else if (/\.(png|jpe?g)$/i.test(e.name)) out.push(p)
    }
  })(dir)
  return out
}

function freezeScreenshots(runId: string, since: number): number {
  // Freeze ad-hoc screenshots (anything in e2e/screenshots/ except __story)
  const dest = path.join(RUNS_DIR, runId, 'screenshots')
  fs.mkdirSync(dest, { recursive: true })
  let n = 0
  for (const src of listShots(SHOTS)) {
    if (src.startsWith(STORY_ROOT)) continue
    const st = fs.statSync(src)
    if (st.mtimeMs < since) continue
    const rel = path.relative(SHOTS, src)
    const dst = path.join(dest, rel)
    fs.mkdirSync(path.dirname(dst), { recursive: true })
    fs.copyFileSync(src, dst)
    n++
  }
  // Freeze every story directory whole (story.json + step PNGs)
  if (fs.existsSync(STORY_ROOT)) {
    for (const e of fs.readdirSync(STORY_ROOT, { withFileTypes: true })) {
      if (!e.isDirectory()) continue
      const srcDir = path.join(STORY_ROOT, e.name)
      const storyJson = path.join(srcDir, 'story.json')
      if (!fs.existsSync(storyJson)) continue
      const startedAt = (() => {
        try { return JSON.parse(fs.readFileSync(storyJson, 'utf-8')).startedAt as number ?? 0 } catch { return 0 }
      })()
      if (startedAt < since) continue
      const dstDir = path.join(RUNS_DIR, runId, 'story', e.name)
      fs.mkdirSync(dstDir, { recursive: true })
      for (const f of fs.readdirSync(srcDir)) {
        fs.copyFileSync(path.join(srcDir, f), path.join(dstDir, f))
      }
    }
  }
  return n
}

interface StartRunOpts {
  spec?: string             // single spec (legacy)
  specs?: string[]          // many specs (plan-aware multi-case runs)
  planId?: string
  scope?: 'all' | { caseIds: string[] }
}

function startRun(opts: StartRunOpts | string): Run | null {
  // Back-compat: accept legacy string spec arg
  const o: StartRunOpts = typeof opts === 'string' ? { spec: opts } : opts
  if (currentRunId) return null
  const allSpecs = o.specs && o.specs.length ? o.specs : (o.spec ? [o.spec] : [])
  const run: Run = {
    id: newRunId(),
    spec: allSpecs.length === 1 ? allSpecs[0] : allSpecs.join(' '),
    startedAt: Date.now(),
    endedAt: null,
    exitCode: null,
    screenshotCount: 0,
    status: 'running',
    review: null,
    gitHead: currentGitHead(),
    planId: o.planId ?? null,
    planVersion: o.planId ? (getPlan(o.planId)?.version ?? null) : null,
  }
  fs.mkdirSync(path.join(RUNS_DIR, run.id), { recursive: true })
  saveRuns([run, ...loadRuns()])

  // Persist run meta when this is a plan-scoped run.
  if (o.planId) {
    const plan = getPlan(o.planId)
    const scope: RunMeta['scope'] = o.scope ?? 'all'
    // Phase 1: caseStoryMap is populated by convention — story slug == caseId.
    // The story recorder slugifies testInfo.titlePath; specs should set the
    // test title to the case id so the produced story slug matches.
    const caseStoryMap: Record<string, string> = {}
    if (plan) for (const c of plan.cases) caseStoryMap[c.id] = c.id
    saveRunMeta(run.id, {
      planId: o.planId,
      planVersion: plan?.version ?? '',
      scope,
      caseStoryMap,
      tested: captureTestedSnapshot(),
    })
  }

  currentRunId = run.id
  currentOutput = ''
  broadcast('started', { id: run.id })

  const args = ['playwright', 'test', ...allSpecs]
  const child = spawn('npx', args, { cwd: WEB, env: { ...process.env, FORCE_COLOR: '0' } })
  const onChunk = (d: Buffer) => {
    const s = d.toString()
    currentOutput += s
    broadcast('line', { line: s })
  }
  child.stdout.on('data', onChunk)
  child.stderr.on('data', onChunk)
  child.on('close', (code) => {
    const screenshotCount = freezeScreenshots(run.id, run.startedAt)
    fs.writeFileSync(path.join(RUNS_DIR, run.id, 'output.txt'), currentOutput)
    updateRun(run.id, {
      endedAt: Date.now(),
      exitCode: code,
      screenshotCount,
      status: 'awaiting-review',
    })
    currentRunId = null
    broadcast('done', { id: run.id, exitCode: code, screenshotCount })
  })
  return run
}

function listSpecs(): string[] {
  if (!fs.existsSync(E2E)) return []
  return fs.readdirSync(E2E)
    .filter(n => n.endsWith('.spec.ts'))
    .map(n => path.join('e2e', n))
}

function listFrozenShots(runId: string): { rel: string; size: number }[] {
  const root = path.join(RUNS_DIR, runId, 'screenshots')
  if (!fs.existsSync(root)) return []
  const out: { rel: string; size: number }[] = []
  ;(function walk(d: string) {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name)
      if (e.isDirectory()) walk(p)
      else if (/\.(png|jpe?g)$/i.test(e.name)) {
        out.push({ rel: path.relative(root, p), size: fs.statSync(p).size })
      }
    }
  })(root)
  return out.sort((a, b) => a.rel.localeCompare(b.rel))
}

interface FrozenStep { idx: number; title: string; description?: string; name?: string; file: string; htmlFile?: string; durationMs: number }
interface FrozenStory {
  path: string
  testTitle: string
  title: string
  description: string
  steps: FrozenStep[]
}
function listFrozenStories(runId: string): FrozenStory[] {
  const root = path.join(RUNS_DIR, runId, 'story')
  if (!fs.existsSync(root)) return []
  const out: FrozenStory[] = []
  for (const e of fs.readdirSync(root, { withFileTypes: true })) {
    if (!e.isDirectory()) continue
    const j = path.join(root, e.name, 'story.json')
    if (!fs.existsSync(j)) continue
    try {
      const data = JSON.parse(fs.readFileSync(j, 'utf-8')) as Partial<FrozenStory> & { steps?: FrozenStep[] }
      const steps = (data.steps ?? []).map(s => ({ ...s, title: s.title ?? s.name ?? '(unnamed step)' }))
      out.push({
        path: e.name,
        testTitle: data.testTitle ?? e.name,
        title: data.title ?? data.testTitle ?? e.name,
        description: data.description ?? '',
        steps,
      })
    } catch { /* skip */ }
  }
  return out
}

function loadFeedback(runId: string): Feedback[] {
  const p = path.join(RUNS_DIR, runId, 'feedback.json')
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')) as Feedback[] } catch { return [] }
}
function saveFeedback(runId: string, fb: Feedback[]) {
  fs.writeFileSync(path.join(RUNS_DIR, runId, 'feedback.json'), JSON.stringify(fb, null, 2))
}

// ---------- plans + tested snapshot + case results -----------------------
// Plans are *source* artifacts, so they live under web/review-plans/ in git.
// Runs (web/.review/runs/) are local-only and gitignored.
const PLANS_DIR = path.join(WEB, 'review-plans')
const SCRIPTS_DIR = path.join(REPO, 'ask', 'scripts')

function loadPlans(): Plan[] {
  if (!fs.existsSync(PLANS_DIR)) return []
  const out: Plan[] = []
  for (const f of fs.readdirSync(PLANS_DIR)) {
    if (!f.endsWith('.json')) continue
    try { out.push(JSON.parse(fs.readFileSync(path.join(PLANS_DIR, f), 'utf-8')) as Plan) }
    catch { /* skip malformed */ }
  }
  return out.sort((a, b) => a.title.localeCompare(b.title))
}
function getPlan(id: string): Plan | undefined { return loadPlans().find(p => p.id === id) }

function captureTestedSnapshot(): TestedSnapshot {
  const head = currentGitHead() ?? ''
  const shortHead = head ? head.slice(0, 7) : ''
  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD'])
  const status = git(['status', '--porcelain'])
  const scripts: TestedSnapshot['scripts'] = []
  if (fs.existsSync(SCRIPTS_DIR)) {
    for (const e of fs.readdirSync(SCRIPTS_DIR, { withFileTypes: true })) {
      if (!e.isDirectory()) continue
      const m = path.join(SCRIPTS_DIR, e.name, 'manifest.json')
      if (!fs.existsSync(m)) continue
      try {
        const j = JSON.parse(fs.readFileSync(m, 'utf-8')) as { version?: string }
        scripts.push({ id: e.name, version: String(j.version ?? '') })
      } catch { /* skip */ }
    }
  }
  return {
    git: {
      head, shortHead, branch,
      dirty: status.length > 0,
      summary: status ? `${status.split('\n').filter(Boolean).length} dirty file(s)` : 'clean',
    },
    scripts,
    vault: 'unknown',
  }
}

function runMetaPath(runId: string): string { return path.join(RUNS_DIR, runId, 'meta.json') }
function loadRunMeta(runId: string): RunMeta | null {
  const p = runMetaPath(runId)
  if (!fs.existsSync(p)) return null
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')) as RunMeta } catch { return null }
}
function saveRunMeta(runId: string, meta: RunMeta) {
  fs.mkdirSync(path.join(RUNS_DIR, runId), { recursive: true })
  fs.writeFileSync(runMetaPath(runId), JSON.stringify(meta, null, 2))
}

function loadCaseReview(runId: string, caseId: string): Review | null {
  const p = path.join(RUNS_DIR, runId, 'cases', caseId, 'review.json')
  if (!fs.existsSync(p)) return null
  try { return JSON.parse(fs.readFileSync(p, 'utf-8')) as Review } catch { return null }
}
function saveCaseReview(runId: string, caseId: string, review: Review | null) {
  const dir = path.join(RUNS_DIR, runId, 'cases', caseId)
  fs.mkdirSync(dir, { recursive: true })
  const p = path.join(dir, 'review.json')
  if (!review) { try { fs.unlinkSync(p) } catch { /* */ } return }
  fs.writeFileSync(p, JSON.stringify(review, null, 2))
}

/** Resolve the storyPath (story dir name) for a case. Looks in run meta first,
 *  then falls back to a story whose `caseId` field matches. */
function resolveCaseStoryPath(runId: string, caseId: string): string | null {
  const meta = loadRunMeta(runId)
  const fromMeta = meta?.caseStoryMap?.[caseId]
  if (fromMeta) return fromMeta
  // Fall back: search frozen stories for an embedded caseId field
  const root = path.join(RUNS_DIR, runId, 'story')
  if (!fs.existsSync(root)) return null
  for (const e of fs.readdirSync(root, { withFileTypes: true })) {
    if (!e.isDirectory()) continue
    const j = path.join(root, e.name, 'story.json')
    if (!fs.existsSync(j)) continue
    try {
      const data = JSON.parse(fs.readFileSync(j, 'utf-8')) as { caseId?: string }
      if (data.caseId === caseId) return e.name
    } catch { /* skip */ }
  }
  return null
}

function caseResultsForRun(run: Run): CaseResult[] {
  const meta = loadRunMeta(run.id)
  if (!meta) return []
  const plan = getPlan(meta.planId)
  if (!plan) return []
  const inScope = (cid: string) => meta.scope === 'all' || meta.scope.caseIds.includes(cid)
  const fb = loadFeedback(run.id)
  return plan.cases.map(c => {
    const storyPath = resolveCaseStoryPath(run.id, c.id)
    let stepCount = 0
    if (storyPath) {
      const j = path.join(RUNS_DIR, run.id, 'story', storyPath, 'story.json')
      try { stepCount = (JSON.parse(fs.readFileSync(j, 'utf-8')) as { steps?: unknown[] }).steps?.length ?? 0 } catch { /* */ }
    }
    const caseFb = storyPath ? fb.filter(f => f.storyPath === storyPath) : []
    const counts = new Map<string, number>()
    for (const f of caseFb) counts.set(f.kind, (counts.get(f.kind) ?? 0) + 1)
    const review = loadCaseReview(run.id, c.id)
    let status: CaseResult['status'] = 'pending'
    if (c.status === 'pending') status = 'pending'
    else if (!inScope(c.id)) status = 'skipped'
    else if (run.status === 'running' && !storyPath) status = 'running'
    else if (storyPath) status = run.exitCode === null ? 'running' : run.exitCode === 0 ? 'passed' : 'failed'
    else status = 'pending'
    return {
      caseId: c.id,
      title: c.title,
      surface: c.surface,
      status,
      storyPath,
      stepCount,
      feedback: Array.from(counts.entries()).map(([kind, count]) => ({ kind, count })),
      decision: review?.decision ?? null,
    }
  })
}

function runDecisionRollup(results: CaseResult[]): Review['decision'] | null {
  const considered = results.filter(r => r.status === 'passed' || r.status === 'failed')
  if (!considered.length) return null
  if (considered.some(r => r.decision === 'rejected')) return 'rejected'
  if (considered.every(r => r.decision === 'approved')) return 'approved'
  return 'changes-requested'
}

// ---------- HTML page (SPA with hash routing) -----------------------------
const HTML = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<title>Ask · review</title>
<style>
  /* ---------- theme tokens (light default, dark via [data-theme=dark]) ---------- */
  :root {
    color-scheme: light;
    --bg:        #f6f7fa;
    --panel:     #ffffff;
    --text:      #1a1a1c;
    --muted:     #6b7280;
    --border:    #e5e7eb;
    --header:    #ffffff;
    --header-bd: #e5e7eb;
    --row-hover: #f3f4f6;
    --code-bg:   #f9fafb;
    --link:      #0066cc;
    --pill-bg:   #eef0f3;
    --primary:   #0066cc;
    --primary-h: #0077ee;
    --success:   #1d6f1d;
    --danger:    #b91c1c;
    --rail:      #e5e7eb;
    --dot:       #cbd5e1;
    --dot-fb:    #0066cc;
    --shadow:    0 1px 2px rgba(0,0,0,0.04), 0 1px 3px rgba(0,0,0,0.06);
    /* badge palettes */
    --b-running-bg:  #e3f7e3; --b-running-fg:  #1d6f1d;
    --b-awaiting-bg: #fef3c7; --b-awaiting-fg: #92400e;
    --b-reviewed-bg: #dbeafe; --b-reviewed-fg: #1e40af;
    --b-passed-bg:   #e3f7e3; --b-passed-fg:   #1d6f1d;
    --b-failed-bg:   #fee2e2; --b-failed-fg:   #b91c1c;
    --b-stale-bg:    #fff7ed; --b-stale-fg:    #c2410c;
    --d-approved:           #1d6f1d;
    --d-changes-requested:  #92400e;
    --d-rejected:           #b91c1c;
  }
  [data-theme="dark"] {
    color-scheme: dark;
    --bg:        #0b0b0c;
    --panel:     #131316;
    --text:      #eee;
    --muted:     #9ca3af;
    --border:    #262629;
    --header:    #111;
    --header-bd: #2a2a2a;
    --row-hover: #14141a;
    --code-bg:   #0a0a0c;
    --link:      #4aa3ff;
    --pill-bg:   #1a1a1c;
    --primary:   #0066cc;
    --primary-h: #0077ee;
    --success:   #1d6f1d;
    --danger:    #6b1a1a;
    --rail:      #262629;
    --dot:       #444;
    --dot-fb:    #4aa3ff;
    --shadow:    none;
    --b-running-bg:  #0a4d0a; --b-running-fg:  #afe9af;
    --b-awaiting-bg: #4d3d0a; --b-awaiting-fg: #f5d77a;
    --b-reviewed-bg: #0a3a4d; --b-reviewed-fg: #a4d8ee;
    --b-passed-bg:   #0a4d0a; --b-passed-fg:   #afe9af;
    --b-failed-bg:   #4d0a0a; --b-failed-fg:   #ee9c9c;
    --b-stale-bg:    #6b1a1a; --b-stale-fg:    #ffc9c9;
    --d-approved:          #afe9af;
    --d-changes-requested: #f5d77a;
    --d-rejected:          #ee9c9c;
  }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); }
  /* ----- Floating menu trigger + slide-out side panel
     Replaces the old sticky top toolbar. The trigger sits in the corner so
     screenshots get the full vertical space; the panel slides in from the
     left when opened. ----- */
  #menu-trigger { position: fixed; top: 10px; left: 12px; z-index: 30; width: 38px; height: 38px; display: flex; align-items: center; justify-content: center; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; box-shadow: var(--shadow); cursor: pointer; padding: 0; }
  #menu-trigger svg { width: 20px; height: 20px; }
  #menu-trigger:hover { background: var(--row-hover); }
  #status-pill { position: fixed; top: 18px; right: 14px; z-index: 30; }
  #side-panel { position: fixed; top: 0; left: 0; bottom: 0; width: 280px; background: var(--panel); border-right: 1px solid var(--border); box-shadow: 4px 0 18px rgba(0,0,0,0.12); z-index: 40; transform: translateX(-110%); transition: transform .22s ease; padding: 16px; display: flex; flex-direction: column; gap: 12px; overflow-y: auto; }
  #side-panel.open { transform: translateX(0); }
  #side-panel h1 { font-size: 14px; margin: 0; font-weight: 600; padding-right: 30px; }
  #side-panel h1 a { color: inherit; text-decoration: none; }
  #side-panel .group { display: flex; flex-direction: column; gap: 6px; }
  #side-panel .group label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
  #side-panel .group select, #side-panel .group button, #side-panel .group a button { width: 100%; text-align: left; }
  #side-panel #theme-toggle { display: inline-flex; align-items: center; gap: 8px; }
  #side-panel #theme-toggle svg { width: 18px; height: 18px; flex-shrink: 0; }
  #side-panel #close-panel { position: absolute; top: 10px; right: 10px; width: 28px; height: 28px; display: flex; align-items: center; justify-content: center; padding: 0; background: transparent; border: none; cursor: pointer; }
  #side-panel #close-panel svg { width: 16px; height: 16px; }
  #side-panel #close-panel:hover { background: var(--row-hover); border-radius: 4px; }
  #panel-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.35); opacity: 0; pointer-events: none; transition: opacity .2s ease; z-index: 35; }
  #panel-backdrop.open { opacity: 1; pointer-events: auto; }
  select, button, input, textarea { background: var(--panel); color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 6px 10px; font: inherit; }
  button { cursor: pointer; }
  select:hover, button:hover:not(:disabled) { background: var(--row-hover); }
  button.primary { background: var(--primary); border-color: var(--primary); color: #fff; }
  button.primary:hover { background: var(--primary-h); }
  button.danger { background: var(--danger); border-color: var(--danger); color: #fff; }
  button.success { background: var(--success); border-color: var(--success); color: #fff; }
  button.icon-only { padding: 5px 7px; line-height: 1; }
  button.icon-only svg { width: 18px; height: 18px; display: block; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  main { padding: 16px 16px 16px 60px; max-width: 1400px; margin: 0 auto; }
  table { width: 100%; border-collapse: collapse; background: var(--panel); border-radius: 8px; overflow: hidden; box-shadow: var(--shadow); }
  table th, table td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--border); vertical-align: top; }
  table tr:last-child td { border-bottom: 0; }
  table th { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; font-weight: 600; }
  table tr:hover td { background: var(--row-hover); }
  table tr.clickable { cursor: pointer; }
  .empty { color: var(--muted); padding: 28px; text-align: center; background: var(--panel); border-radius: 8px; }
  .badge { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; display: inline-block; }
  .badge.running  { background: var(--b-running-bg);  color: var(--b-running-fg); }
  .badge.awaiting { background: var(--b-awaiting-bg); color: var(--b-awaiting-fg); }
  .badge.reviewed { background: var(--b-reviewed-bg); color: var(--b-reviewed-fg); }
  .badge.passed   { background: var(--b-passed-bg);   color: var(--b-passed-fg); }
  .badge.failed   { background: var(--b-failed-bg);   color: var(--b-failed-fg); }
  .badge.stale    { background: var(--b-stale-bg);    color: var(--b-stale-fg); }
  .decision-approved { color: var(--d-approved); font-weight: 600; }
  .decision-changes-requested { color: var(--d-changes-requested); font-weight: 600; }
  .decision-rejected { color: var(--d-rejected); font-weight: 600; }
  a { color: var(--link); text-decoration: none; }
  a:hover { text-decoration: underline; }
  textarea { width: 100%; min-height: 60px; resize: vertical; font-family: inherit; }
  pre.output { background: var(--code-bg); border: 1px solid var(--border); border-radius: 6px; padding: 10px; max-height: 280px; overflow: auto; font: 11px/1.5 ui-monospace,monospace; white-space: pre-wrap; }
  .panel { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin: 16px 0; box-shadow: var(--shadow); }
  .panel h3 { margin: 0 0 8px; font-size: 13px; color: var(--muted); }
  .panel .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .panel .help { color: var(--muted); font-size: 12px; margin-top: 10px; line-height: 1.6; }
  /* Run summary header — compact one-line strip; full prose lives in the side panel */
  .run-hero { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin: 0 0 8px; }
  .run-hero h1 { margin: 0; font-size: 16px; line-height: 1.25; font-weight: 600; flex: 0 1 auto; }
  .run-hero .meta { color: var(--muted); font-size: 11px; }
  .run-hero .info-btn { background: transparent; border: none; padding: 2px 6px; color: var(--muted); cursor: pointer; font-size: 12px; }
  .run-hero .info-btn:hover { color: var(--primary); }
  /* ----- Sticky mini-map flowchart -----
     Dot color now means "where you are":
       - default grey   = step you haven't viewed
       - blue ring      = step you're on
       - dark           = step you already passed
     A separate small badge by the number indicates feedback count, so
     "I left a note here" is no longer confused with "I'm here". */
  .mini-map { position: sticky; top: 0; z-index: 15; background: var(--bg); padding: 6px 0 8px; border-bottom: 1px solid var(--border); margin: 0 0 8px; }
  .mini-map .nodes { display: flex; gap: 0; align-items: center; overflow-x: auto; padding-bottom: 2px; }
  .mini-map .node { flex: 1 1 0; min-width: 70px; display: flex; flex-direction: row; align-items: center; gap: 6px; cursor: pointer; padding: 4px 6px; border-radius: 6px; position: relative; justify-content: center; }
  .mini-map .node:hover { background: var(--row-hover); }
  .mini-map .node .dot { width: 22px; height: 22px; border-radius: 50%; background: var(--dot); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 700; flex-shrink: 0; transition: transform .12s ease, box-shadow .12s ease, background .12s ease; }
  .mini-map .node.passed .dot { background: var(--muted); }
  .mini-map .node.current .dot { background: var(--primary); box-shadow: 0 0 0 3px rgba(0,102,204,0.22); }
  .mini-map .node .cap { font-size: 11px; color: var(--text); line-height: 1.2; max-width: 110px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .mini-map .node.current .cap { font-weight: 600; }
  .mini-map .node .fb-count { position: absolute; top: -2px; left: 22px; min-width: 14px; height: 14px; padding: 0 3px; border-radius: 7px; background: var(--success); color: #fff; font-size: 9px; font-weight: 700; display: flex; align-items: center; justify-content: center; border: 2px solid var(--bg); }
  .mini-map .arrow { flex: 0 0 14px; height: 2px; background: var(--rail); }
  /* ----- Slide: image left, sidebar right (title/description/feedback)
     The image always sits at the top of the panel; text on the right grows
     downward without ever pushing the image. ----- */
  .slide { display: grid; grid-template-columns: 320px minmax(0, 1fr); grid-template-rows: auto auto; gap: 16px; padding: 14px 16px 14px; }
  @media (max-width: 900px) { .slide { grid-template-columns: 1fr; } }
  .slide .step-side  { grid-column: 1; grid-row: 1; display: flex; flex-direction: column; gap: 12px; min-width: 0; }
  .slide .step-image { grid-column: 2; grid-row: 1; }
  .slide .slide-nav  { grid-column: 1 / -1; grid-row: 2; }
  .slide .step-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; }
  .slide .step-meta { color: var(--muted); font-size: 12px; margin: 0; }
  .slide .step-title { font-size: 22px; font-weight: 600; margin: 0; line-height: 1.25; }
  .slide .step-desc { color: var(--text); font-size: 15px; line-height: 1.6; margin: 0; }
  /* ----- Image / HTML view shell + pin overlay ----- */
  .slide .view-toolbar { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; flex-wrap: wrap; }
  .slide .view-toolbar .seg { display: inline-flex; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
  .slide .view-toolbar .seg button { border: none; border-right: 1px solid var(--border); border-radius: 0; padding: 4px 10px; font-size: 12px; background: var(--panel); }
  .slide .view-toolbar .seg button:last-child { border-right: none; }
  .slide .view-toolbar .seg button.active { background: var(--primary); color: #fff; }
  .slide .view-toolbar .toolbar-spacer { flex: 1; }
  .slide .view-toolbar button.tool { font-size: 12px; padding: 4px 10px; display: inline-flex; align-items: center; gap: 4px; }
  .slide .view-toolbar button.tool svg { width: 14px; height: 14px; }
  .slide .step-shot-wrap { position: relative; display: flex; justify-content: center; align-items: center; background: var(--code-bg); border: 1px solid var(--border); border-radius: 8px; padding: 8px; min-height: 200px; }
  .slide .step-shot-wrap.pinning { cursor: crosshair; }
  .slide .step-shot { max-width: 100%; max-height: calc(100vh - 280px); object-fit: contain; border-radius: 4px; user-select: none; -webkit-user-drag: none; }
  .slide .step-shot.idle { cursor: zoom-in; }
  .slide .html-frame { width: 100%; height: calc(100vh - 280px); border: 1px solid var(--border); border-radius: 4px; background: #fff; }
  /* pin layer sits exactly over the rendered image */
  .slide .pin-layer { position: absolute; pointer-events: none; }
  .slide .pin-layer .pin { position: absolute; transform: translate(-50%, -100%); pointer-events: auto; cursor: grab; user-select: none; }
  .slide .pin-layer .pin.dragging { cursor: grabbing; }
  .slide .pin-layer .pin .marker { width: 26px; height: 32px; display: flex; align-items: center; justify-content: center; padding-bottom: 6px; font-size: 11px; font-weight: 700; filter: drop-shadow(0 2px 3px rgba(0,0,0,.35)); position: relative; }
  .slide .pin-layer .pin .marker svg { position: absolute; inset: 0; width: 100%; height: 100%; }
  .slide .pin-layer .pin .marker .num { position: relative; z-index: 1; color: #fff; }
  /* pin colors per kind */
  .pin-kind-ok        { color: #1d6f1d; }
  .pin-kind-bug       { color: #b91c1c; }
  .pin-kind-style     { color: #7c3aed; }
  .pin-kind-copy      { color: #0891b2; }
  .pin-kind-confusing { color: #ca8a04; }
  .pin-kind-slow      { color: #c2410c; }
  .pin-kind-other     { color: #475569; }
  /* inline comment popover */
  .cmt-popover { position: absolute; z-index: 30; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; box-shadow: 0 8px 24px rgba(0,0,0,.18); padding: 10px; width: 320px; max-width: calc(100vw - 40px); transform: translate(-50%, 8px); }
  [data-theme="dark"] .cmt-popover { box-shadow: 0 8px 24px rgba(0,0,0,.5); }
  .cmt-popover .kind-row { display: flex; gap: 4px; flex-wrap: wrap; margin-bottom: 8px; }
  .cmt-popover .kind-row button { padding: 4px 8px; font-size: 12px; display: inline-flex; align-items: center; gap: 4px; }
  .cmt-popover .kind-row button svg { width: 14px; height: 14px; }
  .cmt-popover .kind-row button.selected { background: var(--primary); color: #fff; border-color: var(--primary); }
  .cmt-popover textarea { min-height: 60px; font-size: 13px; }
  .cmt-popover .actions { display: flex; gap: 6px; margin-top: 8px; justify-content: flex-end; }
  .cmt-popover .actions button { font-size: 12px; padding: 5px 10px; }
  .slide .quick { margin-top: 0; display: flex; gap: 6px; flex-wrap: wrap; }
  .slide .quick button { font-size: 13px; padding: 6px 12px 6px 10px; display: inline-flex; align-items: center; gap: 6px; }
  .slide .quick button svg { width: 18px; height: 18px; flex-shrink: 0; }
  .slide .quick button:hover { border-color: var(--primary); color: var(--primary); }
  .slide .fb-list { margin-top: 12px; display: flex; flex-direction: column; gap: 6px; }
  .slide .fb-row { background: var(--pill-bg); border: 1px solid var(--border); border-radius: 6px; padding: 8px 12px; font-size: 13px; display: flex; gap: 10px; align-items: flex-start; }
  .slide .fb-row .kind { font-weight: 600; min-width: 100px; display: inline-flex; align-items: center; gap: 6px; text-transform: capitalize; }
  .slide .fb-row .kind svg { width: 16px; height: 16px; flex-shrink: 0; }
  .slide .fb-row .text { color: var(--text); flex: 1; }
  .slide .fb-row .x { color: var(--muted); cursor: pointer; display: inline-flex; align-items: center; padding: 0 2px; }
  .slide .fb-row .x svg { width: 14px; height: 14px; }
  .slide .fb-row .x:hover { color: var(--danger); }
  /* ----- Slide nav row: prev | quick-tags | next ----- */
  .slide-nav { display: flex; align-items: center; gap: 8px; margin: 8px 0 0; }
  .slide-nav > #prev, .slide-nav > #next { padding: 6px 12px; display: inline-flex; align-items: center; gap: 4px; font-size: 13px; flex-shrink: 0; }
  .slide-nav > #prev svg, .slide-nav > #next svg { width: 14px; height: 14px; }
  .slide-nav > #prev:disabled, .slide-nav > #next:disabled { visibility: hidden; }
  .slide-nav .quick { flex: 1; display: flex; gap: 6px; flex-wrap: wrap; justify-content: center; margin: 0; }
  /* ----- Compact, collapsible review form pinned to the bottom ----- */
  .review-sticky { position: sticky; bottom: 0; z-index: 14; background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 8px 12px; margin: 12px 0 0; box-shadow: 0 -4px 14px rgba(0,0,0,0.06); }
  [data-theme="dark"] .review-sticky { box-shadow: 0 -4px 14px rgba(0,0,0,0.3); }
  .review-sticky .head { display: flex; justify-content: space-between; align-items: center; gap: 8px; flex-wrap: wrap; }
  .review-sticky .head h3 { margin: 0; font-size: 12px; color: var(--muted); }
  .review-sticky[open] .head { margin-bottom: 8px; }
  .review-sticky textarea { min-height: 42px; }
  .review-sticky .row { margin-top: 6px; display: flex; gap: 6px; flex-wrap: wrap; }
  .review-sticky .row button { padding: 5px 10px; font-size: 12px; }
  .review-sticky .help { display: none; }
  .review-sticky summary { cursor: pointer; list-style: none; }
  .review-sticky summary::-webkit-details-marker { display: none; }
  /* Lightbox with zoom/pan */
  dialog#lightbox { background: rgba(0,0,0,0.95); border: none; width: 100vw; height: 100vh; max-width: 100vw; max-height: 100vh; padding: 0; margin: 0; overflow: hidden; }
  dialog#lightbox::backdrop { background: rgba(0,0,0,0.9); }
  #lb-stage { width: 100vw; height: 100vh; overflow: hidden; cursor: grab; user-select: none; touch-action: none; }
  #lb-stage.dragging { cursor: grabbing; }
  #lb-stage img { display: block; transform-origin: 0 0; user-select: none; -webkit-user-drag: none; pointer-events: none; }
  #lb-controls { position: fixed; top: 14px; right: 14px; z-index: 50; display: flex; gap: 6px; }
  #lb-controls button { background: rgba(255,255,255,0.92); color: #111; border: none; border-radius: 6px; width: 36px; height: 36px; font-size: 18px; cursor: pointer; display: flex; align-items: center; justify-content: center; }
  #lb-controls button:hover { background: #fff; }
  #lb-hint { position: fixed; bottom: 14px; left: 50%; transform: translateX(-50%); background: rgba(0,0,0,0.7); color: #fff; padding: 6px 12px; border-radius: 4px; font-size: 12px; pointer-events: none; }
  /* Misc */
  .muted { color: var(--muted); font-size: 12px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 12px; }
  figure { margin: 0; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; box-shadow: var(--shadow); }
  figure img { display: block; width: 100%; cursor: zoom-in; background: var(--code-bg); }
  figcaption { padding: 7px 10px; font-size: 11px; color: var(--muted); display: flex; justify-content: space-between; border-top: 1px solid var(--border); }
  /* ----- Cards (plan + case galleries) ----- */
  .gallery { display: grid; grid-template-columns: 1fr; gap: 14px; }
  .card { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; box-shadow: var(--shadow); cursor: pointer; transition: transform .12s ease, box-shadow .12s ease, border-color .12s ease; }
  .card:hover { border-color: var(--primary); transform: translateY(-1px); box-shadow: 0 4px 14px rgba(0,0,0,0.06); }
  [data-theme="dark"] .card:hover { box-shadow: 0 4px 14px rgba(0,0,0,0.5); }
  .card .head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; margin-bottom: 4px; }
  .card .head h2 { margin: 0; font-size: 17px; font-weight: 600; }
  .card .head .ver { color: var(--muted); font-size: 12px; }
  .card .desc { color: var(--text); font-size: 13px; line-height: 1.55; margin: 4px 0 10px; }
  .card .meta { color: var(--muted); font-size: 12px; display: flex; flex-wrap: wrap; gap: 14px; }
  .card .meta code { background: var(--code-bg); padding: 1px 5px; border-radius: 3px; font-size: 11px; }
  .card .actions { margin-top: 10px; display: flex; gap: 6px; flex-wrap: wrap; }
  .card .actions button { font-size: 12px; padding: 5px 12px; }
  /* Step thumbnail strip */
  .strip { display: flex; gap: 8px; margin-top: 12px; overflow-x: auto; padding-bottom: 4px; }
  .thumb { flex: 0 0 130px; border: 1px solid var(--border); border-radius: 6px; overflow: hidden; cursor: pointer; background: var(--panel); transition: border-color .12s ease, transform .12s ease; }
  .thumb:hover { border-color: var(--primary); transform: translateY(-1px); }
  .thumb .img { aspect-ratio: 16/10; background: var(--code-bg); position: relative; display: flex; align-items: center; justify-content: center; overflow: hidden; }
  .thumb .img img { width: 100%; height: 100%; object-fit: cover; display: block; }
  /* placeholder slate for unreached / pending steps */
  .thumb.placeholder .img { background: linear-gradient(135deg, var(--code-bg), var(--row-hover)); padding: 8px; flex-direction: column; gap: 4px; text-align: center; }
  .thumb.placeholder .img .ph-num { font-size: 22px; font-weight: 700; color: var(--muted); line-height: 1; }
  .thumb.placeholder .img .ph-dir { font-size: 10px; color: var(--muted); font-family: ui-monospace, monospace; }
  .thumb .num { position: absolute; top: 4px; left: 4px; background: rgba(0,0,0,.55); color: #fff; font-size: 10px; font-weight: 700; padding: 1px 6px; border-radius: 8px; z-index: 1; }
  .thumb .cap { padding: 6px 7px; font-size: 11px; color: var(--text); line-height: 1.25; max-height: 30px; overflow: hidden; text-overflow: ellipsis; }
  .surface-pill { font-size: 10px; padding: 1px 6px; border-radius: 4px; background: var(--pill-bg); color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
  .deps-line code { background: var(--code-bg); padding: 1px 5px; border-radius: 3px; font-size: 11px; margin-right: 4px; }
</style>
</head>
<body data-theme="light">
<button id="menu-trigger" aria-label="Open menu" title="Menu">
  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h16M4 18h16"/></svg>
</button>
<span id="status-pill" class="badge">idle</span>
<div id="panel-backdrop"></div>
<aside id="side-panel" aria-hidden="true">
  <button id="close-panel" aria-label="Close menu" title="Close"></button>
  <h1><a href="#/">Ask · review</a></h1>
  <div class="group" id="panel-about"></div>
  <div class="group">
    <label for="spec">Spec</label>
    <select id="spec"><option value="">All specs</option></select>
  </div>
  <div class="group">
    <button id="run" class="primary">New run</button>
  </div>
  <div class="group">
    <button id="theme-toggle"></button>
  </div>
  <div class="group">
    <a href="http://localhost:5173/dev/markdown" target="_blank"><button>/dev/markdown ↗</button></a>
    <a href="http://localhost:5173/" target="_blank"><button>app ↗</button></a>
  </div>
</aside>
<main id="view"></main>
<dialog id="lightbox">
  <div id="lb-controls">
    <button id="lb-zoom-out" title="Zoom out (-)"></button>
    <button id="lb-zoom-reset" title="Reset (0)">⤢</button>
    <button id="lb-zoom-in" title="Zoom in (+)">+</button>
    <button id="lb-close" title="Close (Esc)">×</button>
  </div>
  <div id="lb-stage"><img alt=""></div>
  <div id="lb-hint">scroll = zoom · drag = pan · double-click = reset</div>
</dialog>
<script>
// Inline SVGs (Heroicons outline, 24x24 viewBox, stroke=currentColor).
// No network dependency, scales cleanly, inherits the button text color.
const SVG = {
  ok:        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/></svg>',
  bug:       '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="13" rx="4.5" ry="6.5"/><line x1="12" y1="6.5" x2="12" y2="19.5"/><path d="M10 5 L8.5 3"/><path d="M14 5 L15.5 3"/><path d="M7.7 9 L4.5 7"/><path d="M16.3 9 L19.5 7"/><path d="M7.5 13 L4 13"/><path d="M16.5 13 L20 13"/><path d="M7.7 17 L4.5 19"/><path d="M16.3 17 L19.5 19"/></svg>',
  style:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a9 9 0 1 0 0 18 1.5 1.5 0 0 0 0-3 1.5 1.5 0 0 1 0-3h2.5a4.5 4.5 0 0 0 4.5-4.5C19 6.4 15.86 3 12 3z"/><circle cx="7.5" cy="11" r=".75" fill="currentColor"/><circle cx="11" cy="7.5" r=".75" fill="currentColor"/><circle cx="15.5" cy="9.5" r=".75" fill="currentColor"/></svg>',
  copy:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 4h8a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/><path d="M9 9h6M9 13h6M9 17h4"/></svg>',
  confusing: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9.879 7.519c1.171-1.025 3.071-1.025 4.242 0 1.172 1.025 1.172 2.687 0 3.712-.203.179-.43.326-.67.442-.745.361-1.45.999-1.45 1.827v.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 5.25h.008v.008H12v-.008Z"/></svg>',
  slow:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/></svg>',
  other:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.25 12.76c0 1.6 1.123 2.994 2.707 3.227 1.068.157 2.148.279 3.238.364.466.037.893.281 1.153.671L12 21l2.652-3.978c.26-.39.687-.634 1.153-.67 1.09-.086 2.17-.208 3.238-.365 1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"/></svg>',
  remove:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 18 18 6M6 6l12 12"/></svg>',
  sun:       '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M5.05 5.05l1.41 1.41M17.54 17.54l1.41 1.41M3 12h2M19 12h2M5.05 18.95l1.41-1.41M17.54 6.46l1.41-1.41"/></svg>',
  moon:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>',
  arrowLeft: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5M12 19l-7-7 7-7"/></svg>',
  arrowRight:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M12 5l7 7-7 7"/></svg>',
  pin:       '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2C8 2 5 5 5 9c0 5 7 13 7 13s7-8 7-13c0-4-3-7-7-7z"/><circle cx="12" cy="9" r="2.5"/></svg>',
  clipboard: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="3" width="8" height="4" rx="1"/><path d="M16 5h2a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h2"/></svg>',
  // Shape used by the pin marker (filled teardrop)
  pinShape:  '<svg viewBox="0 0 26 32" fill="currentColor"><path d="M13 1C6.4 1 1 6.4 1 13c0 8 12 18 12 18s12-10 12-18c0-6.6-5.4-12-12-12z"/></svg>',
};

const KINDS = [
  { id: 'ok',         label: 'OK',         icon: SVG.ok },
  { id: 'bug',        label: 'Bug',        icon: SVG.bug },
  { id: 'style',      label: 'Style',      icon: SVG.style },
  { id: 'copy',       label: 'Copy',       icon: SVG.copy },
  { id: 'confusing',  label: 'Confusing',  icon: SVG.confusing },
  { id: 'slow',       label: 'Slow',       icon: SVG.slow },
];

const view = document.getElementById('view');
const specEl = document.getElementById('spec');
const runEl = document.getElementById('run');
const statusEl = document.getElementById('status-pill');

// ---------- side panel toggle -----------------------------------------------
const sidePanel = document.getElementById('side-panel');
const panelBackdrop = document.getElementById('panel-backdrop');
const menuTrigger = document.getElementById('menu-trigger');
const closePanelBtn = document.getElementById('close-panel');
function setPanel(open) {
  sidePanel.classList.toggle('open', open);
  panelBackdrop.classList.toggle('open', open);
  sidePanel.setAttribute('aria-hidden', open ? 'false' : 'true');
}
menuTrigger.addEventListener('click', () => setPanel(!sidePanel.classList.contains('open')));
panelBackdrop.addEventListener('click', () => setPanel(false));
closePanelBtn.innerHTML = SVG.remove;
closePanelBtn.addEventListener('click', () => setPanel(false));

// ---------- lightbox with zoom + pan ----------------------------------------
const lightbox = document.getElementById('lightbox');
const lbStage = document.getElementById('lb-stage');
const lightboxImg = lbStage.querySelector('img');
let lbScale = 1, lbTx = 0, lbTy = 0;
function lbApply() { lightboxImg.style.transform = 'translate(' + lbTx + 'px,' + lbTy + 'px) scale(' + lbScale + ')'; }
function lbFit() {
  // Fit to viewport at scale=1, centered.
  const vw = window.innerWidth, vh = window.innerHeight;
  const nw = lightboxImg.naturalWidth || 1, nh = lightboxImg.naturalHeight || 1;
  const fit = Math.min(vw / nw, vh / nh, 1);
  lbScale = fit;
  lbTx = (vw - nw * fit) / 2;
  lbTy = (vh - nh * fit) / 2;
  lbApply();
}
function lbZoomAt(factor, cx, cy) {
  const next = Math.max(0.1, Math.min(8, lbScale * factor));
  // keep the point under (cx, cy) stationary
  lbTx = cx - (cx - lbTx) * (next / lbScale);
  lbTy = cy - (cy - lbTy) * (next / lbScale);
  lbScale = next;
  lbApply();
}
function openLightbox(src) {
  lightboxImg.src = src;
  lightbox.showModal();
  if (lightboxImg.complete) lbFit();
  else lightboxImg.onload = () => lbFit();
}
lbStage.addEventListener('wheel', (e) => {
  e.preventDefault();
  const r = lbStage.getBoundingClientRect();
  lbZoomAt(e.deltaY < 0 ? 1.15 : 1/1.15, e.clientX - r.left, e.clientY - r.top);
}, { passive: false });
let dragging = false, dragX = 0, dragY = 0, dragTx = 0, dragTy = 0;
lbStage.addEventListener('pointerdown', (e) => {
  dragging = true; lbStage.classList.add('dragging');
  lbStage.setPointerCapture(e.pointerId);
  dragX = e.clientX; dragY = e.clientY; dragTx = lbTx; dragTy = lbTy;
});
lbStage.addEventListener('pointermove', (e) => {
  if (!dragging) return;
  lbTx = dragTx + (e.clientX - dragX);
  lbTy = dragTy + (e.clientY - dragY);
  lbApply();
});
lbStage.addEventListener('pointerup', (e) => { dragging = false; lbStage.classList.remove('dragging'); try { lbStage.releasePointerCapture(e.pointerId); } catch {} });
lbStage.addEventListener('dblclick', () => lbFit());
document.getElementById('lb-zoom-in').addEventListener('click', () => lbZoomAt(1.25, window.innerWidth/2, window.innerHeight/2));
document.getElementById('lb-zoom-out').addEventListener('click', () => lbZoomAt(1/1.25, window.innerWidth/2, window.innerHeight/2));
document.getElementById('lb-zoom-reset').addEventListener('click', () => lbFit());
document.getElementById('lb-close').addEventListener('click', () => lightbox.close());
document.getElementById('lb-zoom-out').textContent = '−';
lightbox.addEventListener('click', (e) => { if (e.target === lightbox) lightbox.close(); });
window.addEventListener('keydown', (e) => {
  if (!lightbox.open) return;
  if (e.key === '+' || e.key === '=') { e.preventDefault(); lbZoomAt(1.25, window.innerWidth/2, window.innerHeight/2); }
  if (e.key === '-') { e.preventDefault(); lbZoomAt(1/1.25, window.innerWidth/2, window.innerHeight/2); }
  if (e.key === '0') { e.preventDefault(); lbFit(); }
});

function ago(ms) {
  const s = (Date.now() - ms) / 1000;
  if (s < 60) return Math.round(s) + 's ago';
  if (s < 3600) return Math.round(s/60) + 'm ago';
  if (s < 86400) return Math.round(s/3600) + 'h ago';
  return Math.round(s/86400) + 'd ago';
}
function fmt(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024*1024) return (bytes/1024).toFixed(1) + ' KB';
  return (bytes/1024/1024).toFixed(1) + ' MB';
}
function escape(s) { return String(s).replace(/[&<>]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

async function loadSpecs() {
  const r = await fetch('/api/specs').then(r => r.json());
  for (const s of r) {
    const o = document.createElement('option');
    o.value = s; o.textContent = s.replace(/^e2e\\//, '');
    specEl.appendChild(o);
  }
}

// ---------- list view -----------------------------------------------------
async function renderList() {
  const runs = await fetch('/api/runs').then(r => r.json());
  if (!runs.length) {
    view.innerHTML = '<div class="empty">No runs yet — pick a spec and hit "New run".</div>';
    return;
  }
  const rows = runs.map(r => {
    const exitBadge = r.exitCode === null
      ? '<span class="badge running">running</span>'
      : r.exitCode === 0 ? '<span class="badge passed">passed</span>'
                         : '<span class="badge failed">failed</span>';
    const statusBadge = '<span class="badge ' + (
      r.status === 'running' ? 'running' :
      r.status === 'reviewed' ? 'reviewed' : 'awaiting'
    ) + '">' + r.status + '</span>';
    const staleBadge = r.stale ? ' <span class="badge stale" title="Code under web/src or ask/scripts has changed since this run was approved.">may be stale</span>' : '';
    const decision = r.review
      ? '<span class="decision-' + r.review.decision + '">' + r.review.decision + '</span>' +
        (r.review.summary ? ' · ' + escape(r.review.summary).slice(0, 80) : '')
      : '<span class="muted">—</span>';
    return '<tr class="clickable" data-id="' + r.id + '">' +
      '<td>' + ago(r.startedAt) + '<br><span class="muted">' + r.id + '</span></td>' +
      '<td>' + escape(r.spec || '(all specs)').replace(/^e2e\\//,'') + '</td>' +
      '<td>' + exitBadge + '</td>' +
      '<td>' + statusBadge + staleBadge + '</td>' +
      '<td>' + r.screenshotCount + '</td>' +
      '<td>' + decision + '</td>' +
    '</tr>';
  }).join('');
  view.innerHTML =
    '<table><thead><tr>' +
      '<th>When</th><th>Spec</th><th>Result</th><th>Review</th><th>Shots</th><th>Decision · Summary</th>' +
    '</tr></thead><tbody>' + rows + '</tbody></table>';
  view.querySelectorAll('tr.clickable').forEach(tr => {
    tr.addEventListener('click', () => location.hash = '#/run/' + tr.dataset.id);
  });
}

// ---------- detail view ---------------------------------------------------
// scope: { caseId, planId } when entered via #/plan/:id/run/:runId/:caseId
async function renderDetail(id, scope) {
  const r = await fetch('/api/runs/' + id).then(r => r.json());
  if (r.error) { view.innerHTML = '<div class="empty">Run not found.</div>'; return; }
  // If scoped to a case, filter stories to that one case's storyPath.
  if (scope && scope.caseId) {
    const cr = (r.caseResults || []).find(c => c.caseId === scope.caseId);
    const storyPath = cr?.storyPath;
    if (storyPath) r.stories = (r.stories || []).filter(s => s.path === storyPath);
    else r.stories = [];
    r.__scope = scope;
  }
  const fb = r.feedback || [];
  const passedBadge = r.exitCode === null
    ? '<span class="badge running">running</span>'
    : r.exitCode === 0 ? '<span class="badge passed">passed</span>'
                       : '<span class="badge failed">failed</span>';
  const staleBadge = r.stale ? ' <span class="badge stale">may be stale (code changed since approval)</span>' : '';

  // ----- collected steps (flatten across stories) -----
  const stories = r.stories || [];
  const allSteps = stories.flatMap(s => s.steps.map(st => ({ s, st })));
  const fbCountFor = (storyPath, stepIdx) => fb.filter(x => x.storyPath === storyPath && x.stepIdx === stepIdx).length;

  // Restore previously-viewed slide index from sessionStorage so refreshing
  // the page doesn't bounce back to step 1.
  const slideKey = 'slide:' + r.id;
  let slideIdx = parseInt(sessionStorage.getItem(slideKey) || '0', 10);
  if (isNaN(slideIdx) || slideIdx < 0) slideIdx = 0;
  if (slideIdx >= allSteps.length) slideIdx = Math.max(0, allSteps.length - 1);

  // ----- review form (collapsible, pinned to bottom) -----
  let reviewBody = '';
  if (r.review) {
    reviewBody = '<details class="review-sticky" id="review-sticky" open>' +
      '<summary class="head"><h3>Reviewed · <span class="decision-' + r.review.decision + '">' + r.review.decision + '</span> · ' + ago(r.review.reviewedAt) + '</h3>' +
      '<button id="reopen">Reopen</button></summary>' +
      '<p style="margin:0;white-space:pre-wrap;font-size:13px">' + escape(r.review.summary || '(no summary)') + '</p>' +
      '</details>';
  } else if (r.status !== 'running') {
    reviewBody = '<details class="review-sticky" id="review-sticky">' +
      '<summary class="head"><h3>Overall review — click to add an overall comment / approve / reject</h3></summary>' +
      '<textarea id="summary" placeholder="Optional — anything global? Per-step quick-tags above replace most typing."></textarea>' +
      '<div class="row">' +
        '<button class="success" data-decision="approved">Approve</button>' +
        '<button data-decision="changes-requested">Changes requested</button>' +
        '<button class="danger" data-decision="rejected">Reject</button>' +
      '</div>' +
      '</details>';
  }

  // ----- mini-map flowchart (sticky) -----
  let miniMap = '';
  if (allSteps.length) {
    miniMap = '<div class="mini-map" id="mini-map"><div class="nodes">' +
      allSteps.map(({ s, st }, i) => {
        const count = fbCountFor(s.path, st.idx);
        const isCurrent = i === slideIdx;
        const isPassed = i < slideIdx;
        const cls = ['node'];
        if (isCurrent) cls.push('current');
        if (isPassed) cls.push('passed');
        const arrow = i < allSteps.length - 1 ? '<div class="arrow"></div>' : '';
        return '<div class="' + cls.join(' ') + '" data-slide="' + i + '">' +
            '<div class="dot">' + (st.idx+1) + '</div>' +
            (count > 0 ? '<div class="fb-count" title="' + count + ' note' + (count===1?'':'s') + '">' + count + '</div>' : '') +
            '<div class="cap">' + escape(st.title) + '</div>' +
          '</div>' + arrow;
      }).join('') +
    '</div></div>';
  }

  // ----- single-slide rendering (current step only) -----
  let slideHtml = '';
  if (allSteps.length) {
    const { s, st } = allSteps[slideIdx];
    const stepFb = fb.filter(x => x.storyPath === s.path && x.stepIdx === st.idx);
    const shotURL = st.file ? '/runs/' + r.id + '/story/' + encodeURI(s.path) + '/' + encodeURI(st.file) : '';
    const htmlURL = st.htmlFile ? '/runs/' + r.id + '/story/' + encodeURI(s.path) + '/' + encodeURI(st.htmlFile) : '';
    slideHtml =
      '<div class="panel slide" data-story-path="' + escape(s.path) + '" data-step="' + st.idx + '" data-shot-url="' + shotURL + '" data-html-url="' + htmlURL + '">' +
        '<div class="step-image">' +
          '<div class="view-toolbar">' +
            '<div class="seg" id="view-seg">' +
              '<button data-view="image" class="active">Image</button>' +
              (htmlURL ? '<button data-view="html">HTML</button>' : '') +
            '</div>' +
            '<button class="tool" id="add-pin-btn" title="Click then click on the image to drop a pin">' + SVG.pin + '<span>Add pin</span></button>' +
            '<div class="toolbar-spacer"></div>' +
            (htmlURL ? '<button class="tool" id="copy-html-btn">' + SVG.clipboard + '<span>Copy HTML</span></button>' : '') +
            '<button class="tool" id="copy-context-btn">' + SVG.clipboard + '<span>Copy step context</span></button>' +
          '</div>' +
          '<div class="step-shot-wrap" id="shot-wrap">' +
            (shotURL ? '<img class="step-shot idle" id="step-shot" src="' + shotURL + '" alt="' + escape(st.title) + '">' : '') +
            '<div class="pin-layer" id="pin-layer"></div>' +
          '</div>' +
        '</div>' +
        '<div class="step-side">' +
          '<div class="step-head">' +
            '<h2 class="step-title">' + escape(st.title) + '</h2>' +
            '<span class="step-meta">Step ' + (slideIdx+1) + ' / ' + allSteps.length + ' · ' + st.durationMs + 'ms</span>' +
          '</div>' +
          (st.description ? '<p class="step-desc">' + escape(st.description) + '</p>' : '') +
          (stepFb.length ? '<div class="fb-list">' +
            stepFb.map(f => '<div class="fb-row">' +
              '<span class="kind">' + (KINDS.find(k=>k.id===f.kind)?.icon ?? SVG.other) + escape(f.kind) + '</span>' +
              '<span class="text">' + escape(f.text || '') + '</span>' +
              '<span class="x" data-at="' + f.at + '" title="remove">' + SVG.remove + '</span>' +
            '</div>').join('') +
          '</div>' : '') +
        '</div>' +
        '<div class="slide-nav">' +
          '<button id="prev"' + (slideIdx === 0 ? ' disabled' : '') + '>' + SVG.arrowLeft + '<span>Previous</span></button>' +
          '<div class="quick">' +
            KINDS.map(k => '<button data-kind="' + k.id + '">' + k.icon + '<span>' + k.label + '</span></button>').join('') +
            '<button data-kind="other">' + SVG.other + '<span>Comment</span></button>' +
          '</div>' +
          '<button id="next"' + (slideIdx === allSteps.length-1 ? ' disabled' : '') + '><span>Next</span>' + SVG.arrowRight + '</button>' +
        '</div>' +
      '</div>';
  }

  // ----- ad-hoc shots (fallback for specs that don't use story()) -----
  let shotsHtml = '';
  if (r.screenshots?.length) {
    const groups = new Map();
    for (const s of r.screenshots) {
      const top = s.rel.split('/')[0] || '(root)';
      if (!groups.has(top)) groups.set(top, []);
      groups.get(top).push(s);
    }
    for (const [g, items] of groups) {
      shotsHtml += '<div class="panel"><h2 style="margin:0 0 8px;font-size:12px;color:#888;text-transform:uppercase">' + escape(g) + ' — ' + items.length + '</h2>' +
        '<div class="grid">' +
        items.map(s =>
          '<figure><img loading="lazy" src="/runs/' + r.id + '/shots/' + encodeURI(s.rel) + '" alt="' + escape(s.rel) + '">' +
          '<figcaption><span>' + escape(s.rel.split("/").pop()) + '</span><span>' + fmt(s.size) + '</span></figcaption></figure>'
        ).join('') + '</div></div>';
    }
  }

  // ----- friendly hero (one-line strip; full prose in the side panel) -----
  const primaryStory = stories[0];
  const heroTitle = primaryStory?.title || (r.spec || '(all specs)').replace(/^e2e\\//, '').replace(/\\.spec\\.ts$/, '');
  const heroDesc = primaryStory?.description || '';
  // Stash run prose for the side panel "About" section
  window.__askRunInfo = {
    title: heroTitle,
    description: heroDesc,
    spec: (r.spec || '(all specs)').replace(/^e2e\\//, ''),
    id: r.id,
    startedAt: r.startedAt,
  };
  const aboutEl = document.getElementById('panel-about');
  if (aboutEl) {
    aboutEl.innerHTML =
      '<label>About this run</label>' +
      '<div style="font-size:13px;font-weight:600">' + escape(heroTitle) + '</div>' +
      (heroDesc ? '<div class="muted" style="font-size:12px;line-height:1.55">' + escape(heroDesc) + '</div>' : '') +
      '<div class="muted" style="font-size:11px">' + escape(window.__askRunInfo.spec) + ' · ' + r.id + ' · started ' + ago(r.startedAt) + '</div>';
  }

  // Breadcrumb depends on whether we're scoped to a plan + case
  const sc = r.__scope;
  const breadcrumb = sc
    ? '<a href="#/" class="muted" style="font-size:12px">plans</a>' +
      ' <span class="muted">›</span> ' +
      '<a href="#/plan/' + escape(sc.planId) + '" class="muted" style="font-size:12px">' + escape(sc.planId) + '</a>' +
      ' <span class="muted">›</span> ' +
      '<a href="#/plan/' + escape(sc.planId) + '/run/' + escape(r.id) + '" class="muted" style="font-size:12px">run</a>' +
      ' <span class="muted">›</span> ' +
      '<span class="muted" style="font-size:12px">' + escape(sc.caseId) + '</span>'
    : '<a href="#/" class="muted" style="font-size:12px">← all runs</a>';

  view.innerHTML =
    '<div class="run-hero">' +
      breadcrumb +
      '<h1>' + escape(heroTitle) + '</h1>' +
      passedBadge + staleBadge +
      '<button class="info-btn" id="hero-info" title="Show full description">about</button>' +
    '</div>' +
    miniMap +
    slideHtml +
    shotsHtml +
    (reviewBody || '') +
    '<details' + (r.exitCode === 0 ? '' : ' open') + ' style="margin-top:16px"><summary style="cursor:pointer" class="muted">Output</summary>' +
      '<pre class="output" id="run-output">' + escape(r.output ?? '') + '</pre></details>';

  const heroInfoBtn = document.getElementById('hero-info');
  if (heroInfoBtn) heroInfoBtn.addEventListener('click', () => setPanel(true));

  // image lightbox (only when not in pin-add mode and not clicking on a pin)
  view.querySelectorAll('figure img').forEach(img => {
    img.addEventListener('click', () => openLightbox(img.src));
  });
  const stepShot = document.getElementById('step-shot');
  if (stepShot) {
    stepShot.addEventListener('click', (ev) => {
      if (document.getElementById('shot-wrap')?.classList.contains('pinning')) return;
      if (ev.target.closest('.pin')) return;
      openLightbox(stepShot.src);
    });
  }

  // ---------- pinned comments + inline popover ----------
  setupSlideInteractions(r.id, allSteps[slideIdx], fb, () => renderDetail(r.id));

  // ----- slideshow navigation -----
  function goTo(i) {
    if (i < 0 || i >= allSteps.length) return;
    sessionStorage.setItem(slideKey, String(i));
    renderDetail(r.id);
  }
  view.querySelectorAll('.mini-map .node').forEach(n => {
    n.addEventListener('click', () => goTo(parseInt(n.dataset.slide, 10)));
  });
  const prevBtn = document.getElementById('prev');
  const nextBtn = document.getElementById('next');
  if (prevBtn) prevBtn.addEventListener('click', () => goTo(slideIdx - 1));
  if (nextBtn) nextBtn.addEventListener('click', () => goTo(slideIdx + 1));
  // Keyboard: ← / → only fire when no input/textarea is focused
  const keyHandler = (ev) => {
    const tag = (document.activeElement?.tagName || '').toUpperCase();
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
    if (ev.key === 'ArrowRight') { ev.preventDefault(); goTo(slideIdx + 1); }
    if (ev.key === 'ArrowLeft')  { ev.preventDefault(); goTo(slideIdx - 1); }
  };
  // Replace any prior listener so we don't stack them across renders
  if (window.__askKeyHandler) window.removeEventListener('keydown', window.__askKeyHandler);
  window.__askKeyHandler = keyHandler;
  window.addEventListener('keydown', keyHandler);
  // review submit / reopen
  view.querySelectorAll('button[data-decision]').forEach(b => {
    b.addEventListener('click', async () => {
      const summary = (document.getElementById('summary')).value.trim();
      await fetch('/api/runs/' + r.id + '/review', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ summary, decision: b.dataset.decision }),
      });
      renderDetail(r.id);
    });
  });
  const reopen = document.getElementById('reopen');
  if (reopen) reopen.addEventListener('click', async () => {
    await fetch('/api/runs/' + r.id + '/review', { method: 'DELETE' });
    renderDetail(r.id);
  });
  // sidebar "remove" buttons on existing comments
  view.querySelectorAll('.slide .fb-row .x').forEach(x => {
    x.addEventListener('click', async () => {
      const at = parseInt(x.dataset.at, 10);
      await fetch('/api/runs/' + r.id + '/feedback?at=' + at, { method: 'DELETE' });
      renderDetail(r.id);
    });
  });
}

// =============================================================================
// Slide interactions: quick-tag toolbar, image/HTML toggle, pinned comments,
// inline popover, copy buttons. All routed through one function so re-renders
// don't double-bind handlers.
// =============================================================================
function setupSlideInteractions(runId, current, fb, refresh) {
  if (!current) return;
  const { s, st } = current;
  const storyPath = s.path, stepIdx = st.idx;
  const slideEl = document.querySelector('.slide');
  if (!slideEl) return;
  const shotWrap = slideEl.querySelector('#shot-wrap');
  const shotImg = slideEl.querySelector('#step-shot');
  const pinLayer = slideEl.querySelector('#pin-layer');
  const stepFb = fb.filter(x => x.storyPath === storyPath && x.stepIdx === stepIdx);

  // ----- view toggle: Image vs HTML -----
  const viewSeg = slideEl.querySelector('#view-seg');
  if (viewSeg) {
    viewSeg.querySelectorAll('button').forEach(btn => {
      btn.addEventListener('click', () => {
        viewSeg.querySelectorAll('button').forEach(b => b.classList.toggle('active', b === btn));
        const mode = btn.dataset.view;
        const htmlURL = slideEl.dataset.htmlUrl;
        if (mode === 'html' && htmlURL) {
          // Replace the contents of shot-wrap with a sandboxed iframe.
          // Pin layer kept hidden in HTML view (anchored to image pixels, not DOM).
          shotWrap.innerHTML = '<iframe class="html-frame" sandbox="allow-same-origin" src="' + htmlURL + '"></iframe>';
        } else {
          shotWrap.innerHTML = '<img class="step-shot idle" id="step-shot" src="' + slideEl.dataset.shotUrl + '"><div class="pin-layer" id="pin-layer"></div>';
          // Re-bind interactions for the regenerated DOM
          setupSlideInteractions(runId, current, fb, refresh);
        }
      });
    });
  }

  // ----- pin layer: render existing pinned comments -----
  function renderPins() {
    if (!pinLayer || !shotImg) return;
    pinLayer.innerHTML = '';
    // Position the pin layer to overlap the rendered image rect exactly.
    const rect = shotImg.getBoundingClientRect();
    const wrapRect = shotWrap.getBoundingClientRect();
    pinLayer.style.left = (rect.left - wrapRect.left) + 'px';
    pinLayer.style.top  = (rect.top  - wrapRect.top)  + 'px';
    pinLayer.style.width  = rect.width + 'px';
    pinLayer.style.height = rect.height + 'px';
    let pinNum = 0;
    stepFb.forEach((f) => {
      if (typeof f.x !== 'number' || typeof f.y !== 'number') return;
      pinNum++;
      const pin = document.createElement('div');
      pin.className = 'pin pin-kind-' + f.kind;
      pin.style.left = (f.x * 100) + '%';
      pin.style.top  = (f.y * 100) + '%';
      pin.dataset.at = String(f.at);
      pin.innerHTML = '<div class="marker">' + SVG.pinShape + '<span class="num">' + pinNum + '</span></div>';
      pin.title = f.kind + (f.text ? ': ' + f.text : '');
      attachPinDrag(pin, f);
      pinLayer.appendChild(pin);
    });
  }
  if (shotImg) {
    if (shotImg.complete) renderPins();
    else shotImg.addEventListener('load', renderPins);
    window.addEventListener('resize', renderPins);
  }

  // ----- pin drag-to-move -----
  function attachPinDrag(pin, f) {
    let dragging = false, startX = 0, startY = 0;
    pin.addEventListener('pointerdown', (e) => {
      e.stopPropagation();
      dragging = false;
      startX = e.clientX; startY = e.clientY;
      pin.setPointerCapture(e.pointerId);
    });
    pin.addEventListener('pointermove', (e) => {
      if (Math.abs(e.clientX - startX) + Math.abs(e.clientY - startY) > 4) {
        dragging = true;
        pin.classList.add('dragging');
        const rect = shotImg.getBoundingClientRect();
        const nx = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        const ny = Math.max(0, Math.min(1, (e.clientY - rect.top) / rect.height));
        pin.style.left = (nx * 100) + '%';
        pin.style.top  = (ny * 100) + '%';
        pin.dataset.nx = String(nx);
        pin.dataset.ny = String(ny);
      }
    });
    pin.addEventListener('pointerup', async (e) => {
      try { pin.releasePointerCapture(e.pointerId); } catch {}
      pin.classList.remove('dragging');
      if (dragging) {
        const nx = parseFloat(pin.dataset.nx), ny = parseFloat(pin.dataset.ny);
        await fetch('/api/runs/' + runId + '/feedback?at=' + f.at, {
          method: 'PATCH', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ x: nx, y: ny }),
        });
        refresh();
      } else {
        // Click (no drag) → open editor for this pin
        openPopover({ x: f.x, y: f.y, existing: f });
      }
    });
  }

  // ----- "Add pin" mode: next click on the image drops a new pin -----
  const addPinBtn = slideEl.querySelector('#add-pin-btn');
  if (addPinBtn && shotWrap && shotImg) {
    addPinBtn.addEventListener('click', () => {
      shotWrap.classList.add('pinning');
      addPinBtn.classList.add('active');
    });
    shotImg.addEventListener('click', (e) => {
      if (!shotWrap.classList.contains('pinning')) return;
      e.stopPropagation();
      const rect = shotImg.getBoundingClientRect();
      const nx = (e.clientX - rect.left) / rect.width;
      const ny = (e.clientY - rect.top) / rect.height;
      shotWrap.classList.remove('pinning');
      addPinBtn.classList.remove('active');
      openPopover({ x: nx, y: ny, existing: null });
    });
  }

  // ----- quick-tag toolbar (unpinned comments) -----
  slideEl.querySelectorAll('.slide-nav .quick button[data-kind]').forEach(btn => {
    btn.addEventListener('click', () => {
      const kind = btn.dataset.kind;
      // OK and Slow are zero-text shortcuts — save immediately, no popover.
      if (kind === 'ok' || kind === 'slow') {
        fetch('/api/runs/' + runId + '/feedback', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ storyPath, stepIdx, kind, text: '', x: null, y: null }),
        }).then(refresh);
        return;
      }
      openPopover({ x: null, y: null, existing: null, presetKind: kind });
    });
  });

  // ----- inline popover (replaces window.prompt) -----
  function closePopover() {
    document.querySelectorAll('.cmt-popover').forEach(p => p.remove());
  }
  function openPopover({ x, y, existing, presetKind }) {
    closePopover();
    const pop = document.createElement('div');
    pop.className = 'cmt-popover';
    let chosenKind = existing?.kind || presetKind || 'comment';
    const kindButtons = KINDS.concat([{ id: 'other', label: 'Comment', icon: SVG.other }])
      .map(k => '<button data-k="' + k.id + '"' + (k.id === chosenKind ? ' class="selected"' : '') + '>' + k.icon + '<span>' + k.label + '</span></button>')
      .join('');
    pop.innerHTML =
      '<div class="kind-row">' + kindButtons + '</div>' +
      '<textarea placeholder="Note (optional)">' + (existing?.text ? escape(existing.text) : '') + '</textarea>' +
      '<div class="actions">' +
        (existing ? '<button class="danger" data-act="delete">Delete</button>' : '') +
        '<button data-act="cancel">Cancel</button>' +
        '<button class="primary" data-act="save">Save</button>' +
      '</div>';
    // Position: anchored to pin coords if given, else top-center of image
    const wrapRect = shotWrap.getBoundingClientRect();
    if (typeof x === 'number' && typeof y === 'number' && shotImg) {
      const rect = shotImg.getBoundingClientRect();
      pop.style.left = (rect.left - wrapRect.left + x * rect.width) + 'px';
      pop.style.top  = (rect.top  - wrapRect.top  + y * rect.height + 4) + 'px';
    } else {
      pop.style.left = '50%';
      pop.style.top  = '12px';
    }
    shotWrap.appendChild(pop);
    pop.querySelector('textarea').focus();
    pop.querySelectorAll('.kind-row button').forEach(b => {
      b.addEventListener('click', () => {
        chosenKind = b.dataset.k;
        pop.querySelectorAll('.kind-row button').forEach(x => x.classList.toggle('selected', x === b));
      });
    });
    pop.querySelector('[data-act="cancel"]').addEventListener('click', closePopover);
    if (existing) {
      pop.querySelector('[data-act="delete"]').addEventListener('click', async () => {
        await fetch('/api/runs/' + runId + '/feedback?at=' + existing.at, { method: 'DELETE' });
        closePopover(); refresh();
      });
    }
    pop.querySelector('[data-act="save"]').addEventListener('click', async () => {
      const text = pop.querySelector('textarea').value.trim();
      if (existing) {
        await fetch('/api/runs/' + runId + '/feedback?at=' + existing.at, {
          method: 'PATCH', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ kind: chosenKind, text }),
        });
      } else {
        await fetch('/api/runs/' + runId + '/feedback', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ storyPath, stepIdx, kind: chosenKind, text, x, y }),
        });
      }
      closePopover(); refresh();
    });
    // Esc to dismiss
    pop.querySelector('textarea').addEventListener('keydown', (ev) => {
      if (ev.key === 'Escape') { ev.preventDefault(); closePopover(); }
      if (ev.key === 'Enter' && (ev.metaKey || ev.ctrlKey)) {
        ev.preventDefault();
        pop.querySelector('[data-act="save"]').click();
      }
    });
  }

  // ----- copy HTML / copy step context -----
  const copyHtmlBtn = slideEl.querySelector('#copy-html-btn');
  if (copyHtmlBtn) {
    copyHtmlBtn.addEventListener('click', async () => {
      const url = slideEl.dataset.htmlUrl;
      if (!url) return;
      const html = await fetch(url).then(r => r.text());
      await navigator.clipboard.writeText(html);
      copyHtmlBtn.querySelector('span').textContent = 'Copied!';
      setTimeout(() => { copyHtmlBtn.querySelector('span').textContent = 'Copy HTML'; }, 1500);
    });
  }
  const copyCtxBtn = slideEl.querySelector('#copy-context-btn');
  if (copyCtxBtn) {
    copyCtxBtn.addEventListener('click', async () => {
      const url = slideEl.dataset.htmlUrl;
      const html = url ? await fetch(url).then(r => r.text()) : '';
      const lines = [];
      lines.push('## ' + st.title);
      if (st.description) lines.push('', st.description);
      if (stepFb.length) {
        lines.push('', '### Comments');
        stepFb.forEach((f, i) => {
          const loc = (typeof f.x === 'number') ? ' @ pin ' + (i+1) : '';
          lines.push('- (' + f.kind + loc + ') ' + (f.text || '(no note)'));
        });
      }
      if (html) {
        lines.push('', '### Captured HTML', '\\u0060\\u0060\\u0060html', html, '\\u0060\\u0060\\u0060');
      }
      await navigator.clipboard.writeText(lines.join('\\n'));
      copyCtxBtn.querySelector('span').textContent = 'Copied!';
      setTimeout(() => { copyCtxBtn.querySelector('span').textContent = 'Copy step context'; }, 1500);
    });
  }
}

// =============================================================================
// Plan-first views: plans index, plan detail, run rollup. The case slideshow
// reuses renderDetail() with a caseId scope (filters stories to that one).
// =============================================================================
async function renderPlansList() {
  const [plans, runs] = await Promise.all([
    fetch('/api/plans').then(r => r.json()),
    fetch('/api/runs').then(r => r.json()),
  ]);
  const lastByPlan = new Map();
  for (const r of runs) { if (r.planId && !lastByPlan.has(r.planId)) lastByPlan.set(r.planId, r); }
  if (!plans.length) {
    view.innerHTML =
      '<div class="empty">No plans yet. Drop a JSON plan into <code>web/review-plans/</code> and reload.<br><br>' +
      '<a href="#/all-runs" class="muted">→ legacy: all runs</a></div>';
    return;
  }
  // For each plan, fetch the latest run's stories so we can show 4 case-cover thumbnails.
  const planCovers = await Promise.all(plans.map(async p => {
    const last = lastByPlan.get(p.id);
    if (!last) return { id: p.id, thumbs: [] };
    try {
      const detail = await fetch('/api/runs/' + last.id).then(r => r.json());
      const thumbs = (detail.stories || []).slice(0, 4).map(s => {
        const first = s.steps?.[0];
        return first?.file ? '/runs/' + last.id + '/story/' + encodeURI(s.path) + '/' + encodeURI(first.file) : null;
      }).filter(Boolean);
      return { id: p.id, thumbs };
    } catch { return { id: p.id, thumbs: [] }; }
  }));
  const coverFor = (pid) => (planCovers.find(c => c.id === pid)?.thumbs) || [];

  const cards = plans.map(p => {
    const last = lastByPlan.get(p.id);
    const implemented = p.cases.filter(c => c.status === 'implemented').length;
    const pending = p.cases.filter(c => c.status === 'pending').length;
    const lastBadge = !last ? '<span class="muted">never run</span>'
      : last.exitCode === null ? '<span class="badge running">running</span>'
      : last.exitCode === 0    ? '<span class="badge passed">passed</span>'
                               : '<span class="badge failed">failed</span>';
    const lastStr = last
      ? ago(last.startedAt) + (last.gitHead ? ' · <code>' + escape(last.gitHead.slice(0,7)) + '</code>' : '')
      : '';
    const thumbs = coverFor(p.id);
    const stripHtml = thumbs.length
      ? '<div class="strip">' + thumbs.map((t, i) => '<div class="thumb"><div class="img"><span class="num">' + (i+1) + '</span><img loading="lazy" src="' + t + '"></div></div>').join('') + '</div>'
      : '';
    return '<div class="card" data-id="' + escape(p.id) + '">' +
      '<div class="head"><h2>' + escape(p.title) + '</h2><span class="ver">v' + escape(p.version) + '</span>' + lastBadge + '</div>' +
      (p.description ? '<p class="desc">' + escape(p.description) + '</p>' : '') +
      '<div class="meta">' +
        '<span><strong>' + p.cases.length + '</strong> cases · ' + implemented + ' implemented' + (pending ? ' · ' + pending + ' pending' : '') + '</span>' +
        (last ? '<span>last run ' + lastStr + '</span>' : '') +
      '</div>' +
      stripHtml +
    '</div>';
  }).join('');

  view.innerHTML =
    '<h1 style="margin:8px 0 14px;font-size:20px">Test plans</h1>' +
    '<div class="gallery">' + cards + '</div>' +
    '<div style="margin-top:18px"><a href="#/all-runs" class="muted" style="font-size:12px">→ legacy: all runs</a></div>';
  view.querySelectorAll('.card').forEach(card => {
    card.addEventListener('click', () => location.hash = '#/plan/' + card.dataset.id);
  });
}

async function renderPlanDetail(planId) {
  const [plan, runs] = await Promise.all([
    fetch('/api/plans/' + planId).then(r => r.json()),
    fetch('/api/plans/' + planId + '/runs').then(r => r.json()),
  ]);
  if (plan.error) { view.innerHTML = '<div class="empty">Plan not found.</div>'; return; }
  const lastRun = runs[0];

  // Last-run case data (steps + files for thumbnails) when available.
  let lastDetail = null;
  let lastCaseResults = [];
  if (lastRun) {
    lastDetail = await fetch('/api/runs/' + lastRun.id).then(r => r.json());
    lastCaseResults = lastDetail.caseResults || [];
  }
  const lastByCase = new Map(lastCaseResults.map(c => [c.caseId, c]));
  const storyByCase = new Map();
  for (const s of (lastDetail?.stories || [])) storyByCase.set(s.path, s);

  // Build a case card. Pre-run cases show placeholder slates with the
  // declared step titles + directives so the story is browsable before
  // any run exists. Post-run cases swap in real screenshots.
  const cardFor = (c) => {
    const last = lastByCase.get(c.id);
    const story = (last?.storyPath && storyByCase.get(last.storyPath)) || null;
    const statusBadge = c.status === 'pending'
      ? '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">pending · phase 3</span>'
      : c.status === 'skipped'
      ? '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">skipped</span>'
      : !last
      ? '<span class="muted" style="font-size:12px">never run</span>'
      : last.status === 'passed'  ? '<span class="badge passed">passed</span>'
      : last.status === 'failed'  ? '<span class="badge failed">failed</span>'
      : last.status === 'running' ? '<span class="badge running">running</span>'
      : '<span class="muted">—</span>';
    const surfaceTag = '<span class="surface-pill">' + escape(c.surface) + '</span>';
    const depsLine = c.deps.length
      ? '<span class="deps-line"><span class="muted">deps:</span> ' + c.deps.map(d => '<code>' + escape(d) + '</code>').join('') + '</span>'
      : '';
    const fbLine = last?.feedback?.length
      ? last.feedback.map(f => f.count + ' ' + f.kind).join(' · ')
      : '';

    // Build the strip: real captured images for a finished run, otherwise
    // placeholder slates with step number + directive label.
    const declared = c.steps || [];
    const stripCells = declared.map((s, i) => {
      const captured = story?.steps?.[i];
      if (captured?.file) {
        const url = '/runs/' + lastRun.id + '/story/' + encodeURI(story.path) + '/' + encodeURI(captured.file);
        return '<div class="thumb" data-step="' + i + '">' +
          '<div class="img"><span class="num">' + (i+1) + '</span><img loading="lazy" src="' + url + '"></div>' +
          '<div class="cap">' + escape(s.title) + '</div>' +
        '</div>';
      }
      const dir = s.nav ? 'nav → ' + s.nav : (typeof s.waitMs === 'number' ? 'wait ' + s.waitMs + 'ms' : '');
      return '<div class="thumb placeholder" data-step="' + i + '">' +
        '<div class="img"><div class="ph-num">' + (i+1) + '</div>' +
          (dir ? '<div class="ph-dir">' + escape(dir) + '</div>' : '') + '</div>' +
        '<div class="cap">' + escape(s.title) + '</div>' +
      '</div>';
    }).join('');
    const stripHtml = declared.length ? '<div class="strip">' + stripCells + '</div>' : '';

    const actions = c.status === 'implemented'
      ? '<button class="primary" data-act="run" data-caseid="' + escape(c.id) + '">Run only this case</button>' +
        '<button data-act="open" data-caseid="' + escape(c.id) + '">Open case</button>'
      : '<button data-act="open" data-caseid="' + escape(c.id) + '">Open case</button>';

    return '<div class="card" data-caseid="' + escape(c.id) + '" data-runid="' + escape(lastRun?.id || '') + '" data-storypath="' + escape(story?.path || '') + '">' +
      '<div class="head"><h2>' + escape(c.title) + '</h2>' + surfaceTag + statusBadge + '</div>' +
      (c.description ? '<p class="desc">' + escape(c.description) + '</p>' : '') +
      '<div class="meta">' + depsLine +
        (last ? '<span>' + last.stepCount + ' steps · ' + (fbLine ? '<strong>' + fbLine + '</strong>' : 'no pins') + '</span>' : '') +
      '</div>' +
      stripHtml +
      '<div class="actions">' + actions + '</div>' +
    '</div>';
  };

  // Run history kept compact in a collapsed details panel.
  const runRows = runs.length ? runs.map(r => {
    const exitBadge = r.exitCode === null ? '<span class="badge running">running</span>'
      : r.exitCode === 0 ? '<span class="badge passed">passed</span>' : '<span class="badge failed">failed</span>';
    const sha = r.gitHead ? r.gitHead.slice(0,7) : '—';
    return '<tr class="clickable" data-id="' + r.id + '">' +
      '<td>' + ago(r.startedAt) + '<br><span class="muted">' + r.id + '</span></td>' +
      '<td>' + sha + '</td>' +
      '<td>' + exitBadge + '</td>' +
      '<td>' + (r.review ? '<span class="decision-' + r.review.decision + '">' + r.review.decision + '</span>' : '<span class="muted">—</span>') + '</td>' +
    '</tr>';
  }).join('') : '<tr><td colspan="4" class="muted" style="padding:18px;text-align:center">No runs yet — click "New run" above.</td></tr>';

  view.innerHTML =
    '<div class="run-hero"><a href="#/" class="muted" style="font-size:12px">← all plans</a>' +
      '<h1>' + escape(plan.title) + '</h1>' +
      '<span class="muted">v' + escape(plan.version) + '</span></div>' +
    (plan.description ? '<p class="muted" style="margin:0 0 12px;line-height:1.55">' + escape(plan.description) + '</p>' : '') +
    '<div style="display:flex;justify-content:flex-end;margin:0 0 12px"><button class="primary" id="new-plan-run">New run · all implemented</button></div>' +
    '<div class="gallery">' + plan.cases.map(cardFor).join('') + '</div>' +
    '<details class="panel" style="margin-top:18px"><summary class="muted" style="cursor:pointer">Run history (' + runs.length + ')</summary>' +
    '<table style="margin-top:10px"><thead><tr><th>When</th><th>Git</th><th>Result</th><th>Decision</th></tr></thead><tbody>' + runRows + '</tbody></table></details>';

  document.getElementById('new-plan-run').addEventListener('click', async () => {
    const r = await fetch('/api/plans/' + planId + '/runs', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ scope: 'all' }),
    }).then(r => r.json());
    if (r.error) { alert(r.error); return; }
    if (r.id) location.hash = '#/plan/' + planId + '/run/' + r.id;
  });
  // Card-level click → open case detail
  view.querySelectorAll('.gallery .card').forEach(card => {
    card.addEventListener('click', (ev) => {
      // Let nested buttons handle their own clicks
      if (ev.target.closest('button')) return;
      if (ev.target.closest('.thumb')) return;
      location.hash = '#/plan/' + planId + '/case/' + card.dataset.caseid;
    });
  });
  // Thumb click → if there's a captured story, open the slideshow at that step
  view.querySelectorAll('.gallery .thumb').forEach(thumb => {
    thumb.addEventListener('click', (ev) => {
      ev.stopPropagation();
      const card = thumb.closest('.card');
      const cid = card?.dataset.caseid;
      const rid = card?.dataset.runid;
      const stepIdx = parseInt(thumb.dataset.step, 10);
      if (rid && cid && !thumb.classList.contains('placeholder')) {
        // Set sessionStorage so the slideshow opens on the chosen step
        try { sessionStorage.setItem('slide:' + rid, String(stepIdx)); } catch { /* */ }
        location.hash = '#/plan/' + planId + '/run/' + rid + '/' + cid;
      } else {
        // Placeholder thumb → just open case detail
        if (cid) location.hash = '#/plan/' + planId + '/case/' + cid;
      }
    });
  });
  // Action buttons
  view.querySelectorAll('button[data-act]').forEach(b => {
    b.addEventListener('click', async (ev) => {
      ev.stopPropagation();
      const cid = b.dataset.caseid;
      if (b.dataset.act === 'open') {
        location.hash = '#/plan/' + planId + '/case/' + cid;
        return;
      }
      if (b.dataset.act === 'run') {
        const r = await fetch('/api/plans/' + planId + '/runs', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ scope: { caseIds: [cid] } }),
        }).then(r => r.json());
        if (r.error) { alert(r.error); return; }
        if (r.id) location.hash = '#/plan/' + planId + '/run/' + r.id;
      }
    });
  });
  // Run history rows (inside the collapsed details panel)
  view.querySelectorAll('details tr.clickable').forEach(tr => {
    tr.addEventListener('click', () => location.hash = '#/plan/' + planId + '/run/' + tr.dataset.id);
  });
}

async function renderRunRollup(planId, runId) {
  const [plan, run] = await Promise.all([
    fetch('/api/plans/' + planId).then(r => r.json()),
    fetch('/api/runs/' + runId).then(r => r.json()),
  ]);
  if (run.error || plan.error) { view.innerHTML = '<div class="empty">Run not found.</div>'; return; }
  const tested = run.meta?.tested;
  const t = tested?.git;
  const headerBits = [];
  if (t) headerBits.push('<span class="muted">git</span> <code>' + escape(t.shortHead) + '</code> <span class="muted">on</span> <code>' + escape(t.branch) + '</code>' + (t.dirty ? ' <span class="badge stale">dirty</span>' : ''));
  headerBits.push('<span class="muted">started</span> ' + ago(run.startedAt));
  if (run.endedAt) headerBits.push('<span class="muted">ended</span> ' + ago(run.endedAt));

  const exitBadge = run.exitCode === null ? '<span class="badge running">running</span>'
    : run.exitCode === 0 ? '<span class="badge passed">passed</span>' : '<span class="badge failed">failed</span>';
  const decisionBadge = run.decisionRollup
    ? ' · <span class="decision-' + run.decisionRollup + '">rollup: ' + run.decisionRollup + '</span>' : '';

  // Build a story map so each case can show real screenshots when available.
  const storyByPath = new Map();
  for (const s of (run.stories || [])) storyByPath.set(s.path, s);

  // Find the plan-declared case for richer info (description, declared steps).
  const planCases = new Map((plan.cases || []).map(c => [c.id, c]));

  const caseCards = (run.caseResults || []).map(c => {
    const planCase = planCases.get(c.caseId);
    const story = c.storyPath ? storyByPath.get(c.storyPath) : null;
    const surfaceTag = '<span class="surface-pill">' + escape(c.surface) + '</span>';
    const statusBadge = c.status === 'passed'   ? '<span class="badge passed">passed</span>'
      : c.status === 'failed'                   ? '<span class="badge failed">failed</span>'
      : c.status === 'running'                  ? '<span class="badge running">running</span>'
      : c.status === 'skipped'                  ? '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">skipped</span>'
      :                                           '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">' + escape(c.status) + '</span>';
    const fbLine = c.feedback.length ? c.feedback.map(f => f.count + ' ' + f.kind).join(' · ') : 'no pins';
    const decisionTag = c.decision ? ' · <span class="decision-' + c.decision + '">' + escape(c.decision) + '</span>' : '';

    // Build the strip from declared steps; swap in real screenshots when present.
    const declared = planCase?.steps || (story?.steps || []).map((s, i) => ({ id: 'step-' + i, title: s.title, description: '' }));
    const stripCells = declared.map((ds, i) => {
      const captured = story?.steps?.[i];
      if (captured?.file) {
        const url = '/runs/' + escape(run.id) + '/story/' + encodeURI(story.path) + '/' + encodeURI(captured.file);
        return '<div class="thumb" data-step="' + i + '">' +
          '<div class="img"><span class="num">' + (i+1) + '</span><img loading="lazy" src="' + url + '"></div>' +
          '<div class="cap">' + escape(ds.title) + '</div>' +
        '</div>';
      }
      const dir = ds.nav ? 'nav → ' + ds.nav : (typeof ds.waitMs === 'number' ? 'wait ' + ds.waitMs + 'ms' : '');
      return '<div class="thumb placeholder" data-step="' + i + '">' +
        '<div class="img"><div class="ph-num">' + (i+1) + '</div>' +
          (dir ? '<div class="ph-dir">' + escape(dir) + '</div>' : '') + '</div>' +
        '<div class="cap">' + escape(ds.title) + '</div>' +
      '</div>';
    }).join('');
    const stripHtml = declared.length ? '<div class="strip">' + stripCells + '</div>' : '';

    const actions = c.storyPath
      ? '<button class="primary" data-act="open-slides" data-caseid="' + escape(c.caseId) + '">Open story →</button>'
      : (planCase?.status === 'pending'
          ? '<span class="muted" style="font-size:12px">pending — no run captured</span>'
          : '<span class="muted" style="font-size:12px">no story (test failed before any step)</span>');

    return '<div class="card" data-caseid="' + escape(c.caseId) + '" data-runid="' + escape(run.id) + '" data-storypath="' + escape(c.storyPath || '') + '">' +
      '<div class="head"><h2>' + escape(c.title) + '</h2>' + surfaceTag + statusBadge + '</div>' +
      (planCase?.description ? '<p class="desc">' + escape(planCase.description) + '</p>' : '') +
      '<div class="meta">' +
        '<span>' + (c.stepCount || declared.length) + ' steps · <strong>' + fbLine + '</strong>' + decisionTag + '</span>' +
      '</div>' +
      stripHtml +
      '<div class="actions">' + actions + '</div>' +
    '</div>';
  }).join('');

  const scriptsLine = tested?.scripts?.length
    ? '<p class="muted" style="margin:0 0 12px;font-size:12px">Scripts at run start: ' +
      tested.scripts.slice(0, 8).map(s => escape(s.id) + '@' + escape(s.version)).join(', ') +
      (tested.scripts.length > 8 ? ' …' : '') + '</p>'
    : '';

  view.innerHTML =
    '<div class="run-hero"><a href="#/plan/' + escape(planId) + '" class="muted" style="font-size:12px">← ' + escape(plan.title) + '</a>' +
      '<h1>Run ' + escape(run.id) + '</h1>' + exitBadge + '<span>' + decisionBadge + '</span></div>' +
    '<p class="muted" style="margin:0 0 6px;font-size:12px">' + headerBits.join(' · ') + '</p>' +
    scriptsLine +
    '<div class="gallery">' + caseCards + '</div>' +
    '<details' + (run.exitCode === 0 ? '' : ' open') + ' style="margin-top:16px"><summary style="cursor:pointer" class="muted">Run output</summary>' +
    '<pre class="output" id="run-output">' + escape(run.output ?? '') + '</pre></details>';

  // Card click → open the case's slideshow if a story exists, else go to case detail.
  view.querySelectorAll('.gallery .card').forEach(card => {
    card.addEventListener('click', (ev) => {
      if (ev.target.closest('button')) return;
      if (ev.target.closest('.thumb')) return;
      const cid = card.dataset.caseid;
      const sp = card.dataset.storypath;
      if (sp) location.hash = '#/plan/' + planId + '/run/' + runId + '/' + cid;
      else    location.hash = '#/plan/' + planId + '/case/' + cid;
    });
  });
  // Thumb click → jump to that step in the slideshow.
  view.querySelectorAll('.gallery .thumb').forEach(thumb => {
    thumb.addEventListener('click', (ev) => {
      ev.stopPropagation();
      const card = thumb.closest('.card');
      const cid = card?.dataset.caseid;
      const sp = card?.dataset.storypath;
      const stepIdx = parseInt(thumb.dataset.step, 10);
      if (sp && cid && !thumb.classList.contains('placeholder')) {
        try { sessionStorage.setItem('slide:' + runId, String(stepIdx)); } catch { /* */ }
        location.hash = '#/plan/' + planId + '/run/' + runId + '/' + cid;
      }
    });
  });
  // "Open story →" button
  view.querySelectorAll('button[data-act="open-slides"]').forEach(b => {
    b.addEventListener('click', (ev) => {
      ev.stopPropagation();
      const cid = b.dataset.caseid;
      location.hash = '#/plan/' + planId + '/run/' + runId + '/' + cid;
    });
  });
}

async function renderCaseDetail(planId, caseId) {
  const r = await fetch('/api/plans/' + planId + '/cases/' + caseId).then(r => r.json());
  if (r.error) { view.innerHTML = '<div class="empty">Case not found.</div>'; return; }
  const c = r.case;
  const surfaceTag = '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">' + escape(c.surface) + '</span>';
  const statusBadge = c.status === 'implemented'
    ? '<span class="badge passed">implemented</span>'
    : c.status === 'pending'
      ? '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">pending</span>'
      : '<span class="badge" style="background:var(--pill-bg);color:var(--muted)">' + escape(c.status) + '</span>';
  const depsLine = c.deps && c.deps.length
    ? '<span class="muted">deps:</span> ' + c.deps.map(d => '<code>' + escape(d) + '</code>').join(' · ')
    : '<span class="muted">no dependencies</span>';
  const driverLine = c.spec
    ? '<span class="muted">spec:</span> <code>' + escape(c.spec) + '</code>'
    : c.driver
      ? '<span class="muted">driver:</span> <code>' + escape(c.driver) + '</code>'
      : '';

  const stepsHtml = (c.steps || []).map((s, i) => {
    const directive = s.nav ? '<code>nav → ' + escape(s.nav) + '</code>'
      : s.waitMs ? '<code>wait ' + s.waitMs + 'ms</code>'
      : '<span class="muted">—</span>';
    return '<tr>' +
      '<td style="width:50px"><strong>' + (i+1) + '</strong></td>' +
      '<td><strong>' + escape(s.title) + '</strong><br>' +
        '<span class="muted" style="font-size:11px">' + escape(s.id) + '</span></td>' +
      '<td>' + escape(s.description) + '</td>' +
      '<td style="width:160px">' + directive + '</td>' +
    '</tr>';
  }).join('');

  const historyRows = (r.history || []).length
    ? r.history.map(h => {
        const status = h.status === 'passed' ? '<span class="badge passed">passed</span>'
          : h.status === 'failed' ? '<span class="badge failed">failed</span>'
          : '<span class="badge running">' + escape(h.status) + '</span>';
        const fb = h.feedback.length ? h.feedback.map(f => f.count + ' ' + f.kind).join(' · ') : '<span class="muted">—</span>';
        const decision = h.decision ? '<span class="decision-' + h.decision + '">' + h.decision + '</span>' : '<span class="muted">—</span>';
        return '<tr class="clickable" data-runid="' + escape(h.runId) + '">' +
          '<td>' + ago(h.startedAt) + '<br><span class="muted">' + escape(h.runId) + '</span></td>' +
          '<td>' + status + '</td>' +
          '<td>' + h.stepCount + ' steps</td>' +
          '<td>' + fb + '</td>' +
          '<td>' + decision + '</td>' +
          '<td><a href="#/plan/' + escape(planId) + '/run/' + escape(h.runId) + '/' + escape(c.id) + '">open →</a></td>' +
        '</tr>';
      }).join('')
    : '<tr><td colspan="6" class="muted" style="padding:18px;text-align:center">No runs of this case yet.</td></tr>';

  const isPending = c.status === 'pending';
  const runScopedBtn = !isPending
    ? '<button class="primary" id="run-this-case">Run only this case</button>'
    : '<span class="muted" style="font-size:12px">This case is pending — driver is <code>' + escape(c.driver || 'not set') + '</code> (Phase 3).</span>';

  view.innerHTML =
    '<div class="run-hero">' +
      '<a href="#/plan/' + escape(planId) + '" class="muted" style="font-size:12px">← ' + escape(r.plan.title) + '</a>' +
      '<h1>' + escape(c.title) + '</h1>' + surfaceTag + statusBadge +
    '</div>' +
    (c.description ? '<p class="muted" style="margin:0 0 8px;line-height:1.55">' + escape(c.description) + '</p>' : '') +
    '<p class="muted" style="margin:0 0 14px;font-size:12px">' + depsLine + (driverLine ? ' · ' + driverLine : '') + '</p>' +
    '<div class="panel"><div class="row" style="justify-content:space-between"><h3 style="margin:0">Declared steps · ' + (c.steps ? c.steps.length : 0) + '</h3>' + runScopedBtn + '</div>' +
    (c.steps && c.steps.length
      ? '<table style="margin-top:10px"><thead><tr><th>#</th><th>Step</th><th>Description</th><th>Directive</th></tr></thead>' +
        '<tbody>' + stepsHtml + '</tbody></table>'
      : '<p class="muted" style="margin:8px 0 0">No steps declared yet.</p>') +
    '</div>' +
    '<div class="panel"><h3 style="margin:0 0 8px">Run history for this case</h3>' +
    '<table><thead><tr><th>When</th><th>Status</th><th>Steps</th><th>Pins</th><th>Decision</th><th></th></tr></thead>' +
    '<tbody>' + historyRows + '</tbody></table></div>';

  const runBtn = document.getElementById('run-this-case');
  if (runBtn) {
    runBtn.addEventListener('click', async () => {
      const r = await fetch('/api/plans/' + planId + '/runs', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ scope: { caseIds: [c.id] } }),
      }).then(r => r.json());
      if (r.id) location.hash = '#/plan/' + planId + '/run/' + r.id;
      else if (r.error) alert(r.error);
    });
  }
  view.querySelectorAll('tr.clickable').forEach(tr => {
    tr.addEventListener('click', () => {
      location.hash = '#/plan/' + planId + '/run/' + tr.dataset.runid + '/' + c.id;
    });
  });
}

// ---------- routing -------------------------------------------------------
function route() {
  const h = location.hash;
  // #/plan/:id/run/:runId/:caseId
  let m = h.match(/^#\\/plan\\/([^/]+)\\/run\\/([^/]+)\\/([^/]+)$/);
  if (m) { renderDetail(m[2], { caseId: m[3], planId: m[1] }); return; }
  // #/plan/:id/case/:caseId — case detail view (declared steps, history)
  m = h.match(/^#\\/plan\\/([^/]+)\\/case\\/([^/]+)$/);
  if (m) { renderCaseDetail(m[1], m[2]); return; }
  // #/plan/:id/run/:runId
  m = h.match(/^#\\/plan\\/([^/]+)\\/run\\/([^/]+)$/);
  if (m) { renderRunRollup(m[1], m[2]); return; }
  // #/plan/:id
  m = h.match(/^#\\/plan\\/([^/]+)$/);
  if (m) { renderPlanDetail(m[1]); return; }
  // #/run/:id (legacy)
  m = h.match(/^#\\/run\\/(.+)$/);
  if (m) { renderDetail(m[1]); return; }
  // #/all-runs (legacy table)
  if (h === '#/all-runs') { renderList(); return; }
  renderPlansList();
}
window.addEventListener('hashchange', route);

// ---------- run controls --------------------------------------------------
runEl.addEventListener('click', async () => {
  const r = await fetch('/api/run', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ spec: specEl.value }),
  }).then(r => r.json());
  setPanel(false);
  if (r.id) location.hash = '#/run/' + r.id;
});

const es = new EventSource('/api/output');
es.addEventListener('started', () => { statusEl.textContent = 'running…'; statusEl.className = 'badge running'; runEl.disabled = true; });
es.addEventListener('line', (e) => {
  const out = document.getElementById('run-output');
  if (out) { out.textContent += JSON.parse(e.data).line; out.scrollTop = out.scrollHeight; }
});
es.addEventListener('done', async (e) => {
  statusEl.textContent = 'idle'; statusEl.className = 'badge';
  runEl.disabled = false;
  // Auto-jump into the slideshow for the first finished case so the human
  // sees the captured story without an extra click. Only if (a) the run had
  // a plan and (b) the user hasn't navigated away during the run.
  let payload = {};
  try { payload = JSON.parse(e.data || '{}'); } catch { /* */ }
  const finishedId = payload.id;
  if (finishedId) {
    try {
      const r = await fetch('/api/runs/' + finishedId).then(r => r.json());
      if (r && r.planId && Array.isArray(r.caseResults)) {
        const finished = r.caseResults.filter(c => c.storyPath && (c.status === 'passed' || c.status === 'failed'));
        // Don't yank them out of a slideshow they navigated to mid-run.
        const onSlideshow = !!location.hash.match(/^#\\/plan\\/[^/]+\\/run\\/[^/]+\\/[^/]+$/);
        if (!onSlideshow && finished.length > 0) {
          // Multi-case runs → land on the rollup (gallery of cases) so the
          // user can pick which one to dive into. Single-case runs → drop
          // straight into that case's slideshow.
          if (finished.length === 1) {
            location.hash = '#/plan/' + r.planId + '/run/' + finishedId + '/' + finished[0].caseId;
          } else {
            location.hash = '#/plan/' + r.planId + '/run/' + finishedId;
          }
          return;
        }
      }
    } catch { /* fall through to route() */ }
  }
  route();
});

// ---------- theme toggle (light by default, persisted) -------------------
const themeBtn = document.getElementById('theme-toggle');
function applyTheme(t) {
  document.body.dataset.theme = t;
  const icon = t === 'dark' ? SVG.sun : SVG.moon;
  const label = t === 'dark' ? 'Light theme' : 'Dark theme';
  themeBtn.innerHTML = icon + '<span>' + label + '</span>';
  themeBtn.title = label;
}
applyTheme(localStorage.getItem('ask-review-theme') || 'light');
themeBtn.addEventListener('click', () => {
  const next = document.body.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('ask-review-theme', next);
  applyTheme(next);
});

loadSpecs();
route();
// Refresh the current view periodically so a running test updates the
// status. Use route() so plan-aware paths render the right view (the prior
// version called renderList() unconditionally, which clobbered any plan
// or plan-run page back to the legacy runs table).
setInterval(() => {
  const h = location.hash;
  // Don't disrupt the slideshow — pin/popover state is local to the DOM.
  if (h.startsWith('#/run/')) return;
  if (h.match(/^#\\/plan\\/[^/]+\\/run\\/[^/]+\\/[^/]+$/)) return;
  route();
}, 5000);
</script>
</body></html>`

// ---------- HTTP server ---------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://localhost:${PORT}`)
  const p = url.pathname

  if (p === '/' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    res.end(HTML); return
  }

  if (p === '/api/specs' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(listSpecs())); return
  }

  if (p === '/api/runs' && req.method === 'GET') {
    const runs = loadRuns().map(r => ({ ...r, stale: isPotentiallyStale(r) }))
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(runs)); return
  }

  const runDetail = p.match(/^\/api\/runs\/([^/]+)$/)
  if (runDetail && req.method === 'GET') {
    const r = getRun(runDetail[1])
    if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
    const outputPath = path.join(RUNS_DIR, r.id, 'output.txt')
    const output = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, 'utf-8')
                  : (currentRunId === r.id ? currentOutput : '')
    res.writeHead(200, { 'Content-Type': 'application/json' })
    const meta = loadRunMeta(r.id)
    const caseResults = r.planId ? caseResultsForRun(r) : []
    res.end(JSON.stringify({
      ...r,
      output,
      screenshots: listFrozenShots(r.id),
      stories: listFrozenStories(r.id),
      feedback: loadFeedback(r.id),
      stale: isPotentiallyStale(r),
      meta,
      caseResults,
      decisionRollup: r.planId ? runDecisionRollup(caseResults) : null,
    })); return
  }

  if (p === '/api/run' && req.method === 'POST') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      let spec = ''
      try { spec = (JSON.parse(body) as { spec?: string }).spec ?? '' } catch { /* */ }
      const run = startRun(spec)
      if (!run) { res.writeHead(409, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ error: 'a run is already in progress' })); return }
      res.writeHead(202, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ id: run.id }))
    })
    return
  }

  const review = p.match(/^\/api\/runs\/([^/]+)\/review$/)
  if (review && req.method === 'POST') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      try {
        const { summary, decision } = JSON.parse(body) as { summary: string; decision: Review['decision'] }
        const r = updateRun(review[1], {
          status: 'reviewed',
          review: { summary: summary || '', decision, reviewedAt: Date.now() },
        })
        if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify(r))
      } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: String(e) })) }
    })
    return
  }
  if (review && req.method === 'DELETE') {
    const r = updateRun(review[1], { status: 'awaiting-review', review: null })
    if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(r)); return
  }

  // Per-step feedback endpoints
  const feedback = p.match(/^\/api\/runs\/([^/]+)\/feedback$/)
  if (feedback && req.method === 'POST') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      try {
        const { storyPath, stepIdx, kind, text, x, y } = JSON.parse(body) as Omit<Feedback, 'at'>
        const fb = loadFeedback(feedback[1])
        fb.push({
          storyPath, stepIdx, kind, text: text || '', at: Date.now(),
          x: typeof x === 'number' ? x : null,
          y: typeof y === 'number' ? y : null,
        })
        saveFeedback(feedback[1], fb)
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
      } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: String(e) })) }
    })
    return
  }
  // PATCH: edit text or move pin on an existing comment (matched by `at`)
  if (feedback && req.method === 'PATCH') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      try {
        const at = parseInt(url.searchParams.get('at') ?? '', 10)
        const patch = JSON.parse(body) as Partial<Pick<Feedback, 'text' | 'kind' | 'x' | 'y'>>
        const fb = loadFeedback(feedback[1]).map(f => f.at === at ? { ...f, ...patch } : f)
        saveFeedback(feedback[1], fb)
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify({ ok: true }))
      } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: String(e) })) }
    })
    return
  }
  if (feedback && req.method === 'DELETE') {
    const at = parseInt(url.searchParams.get('at') ?? '', 10)
    const fb = loadFeedback(feedback[1]).filter(f => f.at !== at)
    saveFeedback(feedback[1], fb)
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true })); return
  }

  if (p === '/api/output' && req.method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    })
    res.write(': connected\n\n')
    sseClients.push(res)
    req.on('close', () => {
      const i = sseClients.indexOf(res); if (i >= 0) sseClients.splice(i, 1)
    })
    return
  }

  // ---------- plan + case API (additive) ----------
  if (p === '/api/plans' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(loadPlans())); return
  }
  const planDetail = p.match(/^\/api\/plans\/([^/]+)$/)
  if (planDetail && req.method === 'GET') {
    const plan = getPlan(planDetail[1])
    if (!plan) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(plan)); return
  }
  const planRuns = p.match(/^\/api\/plans\/([^/]+)\/runs$/)
  if (planRuns && req.method === 'GET') {
    const all = loadRuns().filter(r => r.planId === planRuns[1])
      .map(r => ({ ...r, stale: isPotentiallyStale(r) }))
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(all)); return
  }
  if (planRuns && req.method === 'POST') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      const plan = getPlan(planRuns[1])
      if (!plan) { res.writeHead(404); res.end(JSON.stringify({ error: 'plan not found' })); return }
      let scope: RunMeta['scope'] = 'all'
      try { const parsed = JSON.parse(body || '{}'); if (parsed.scope) scope = parsed.scope } catch { /* */ }
      // Resolve which spec(s) to run for the chosen cases.
      const wantedIds = scope === 'all' ? null : new Set(scope.caseIds)
      const specs = plan.cases
        .filter(c => c.status === 'implemented' && c.spec)
        .filter(c => !wantedIds || wantedIds.has(c.id))
        .map(c => `e2e/${c.spec}`)
      if (!specs.length) { res.writeHead(400); res.end(JSON.stringify({ error: 'no implemented cases match the scope' })); return }
      const run = startRun({ specs, planId: plan.id, scope })
      if (!run) { res.writeHead(409); res.end(JSON.stringify({ error: 'a run is already in progress' })); return }
      res.writeHead(202, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ id: run.id }))
    })
    return
  }
  // Plan-level case detail — used by the case detail route to show the
  // declared case + its last result across all runs of this plan.
  const planCaseDetail = p.match(/^\/api\/plans\/([^/]+)\/cases\/([^/]+)$/)
  if (planCaseDetail && req.method === 'GET') {
    const plan = getPlan(planCaseDetail[1])
    if (!plan) { res.writeHead(404); res.end(JSON.stringify({ error: 'plan not found' })); return }
    const c = plan.cases.find(c => c.id === planCaseDetail[2])
    if (!c) { res.writeHead(404); res.end(JSON.stringify({ error: 'case not found' })); return }
    // Walk runs of this plan (newest first) and gather: last result + history.
    const runs = loadRuns().filter(r => r.planId === plan.id)
    const history: Array<{ runId: string; startedAt: number; status: CaseResult['status']; stepCount: number; feedback: CaseResult['feedback']; decision: CaseResult['decision'] }> = []
    for (const r of runs) {
      const results = caseResultsForRun(r)
      const cr = results.find(x => x.caseId === c.id)
      if (!cr) continue
      if (cr.status === 'pending' || cr.status === 'skipped') continue
      history.push({
        runId: r.id, startedAt: r.startedAt, status: cr.status,
        stepCount: cr.stepCount, feedback: cr.feedback, decision: cr.decision,
      })
    }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ plan: { id: plan.id, title: plan.title, version: plan.version }, case: c, history }))
    return
  }
  const caseDetail = p.match(/^\/api\/runs\/([^/]+)\/cases\/([^/]+)$/)
  if (caseDetail && req.method === 'GET') {
    const r = getRun(caseDetail[1])
    if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'run not found' })); return }
    const storyPath = resolveCaseStoryPath(r.id, caseDetail[2])
    const stories = listFrozenStories(r.id)
    const story = storyPath ? stories.find(s => s.path === storyPath) ?? null : null
    const fb = loadFeedback(r.id).filter(f => storyPath ? f.storyPath === storyPath : false)
    const review = loadCaseReview(r.id, caseDetail[2])
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ caseId: caseDetail[2], story, feedback: fb, review })); return
  }
  const caseReview = p.match(/^\/api\/runs\/([^/]+)\/cases\/([^/]+)\/review$/)
  if (caseReview && req.method === 'POST') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      try {
        const { summary, decision } = JSON.parse(body) as { summary: string; decision: Review['decision'] }
        saveCaseReview(caseReview[1], caseReview[2], { summary: summary || '', decision, reviewedAt: Date.now() })
        res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: true }))
      } catch (e) { res.writeHead(400); res.end(JSON.stringify({ error: String(e) })) }
    })
    return
  }
  if (caseReview && req.method === 'DELETE') {
    saveCaseReview(caseReview[1], caseReview[2], null)
    res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: true })); return
  }

  // Frozen ad-hoc screenshot
  const runShot = p.match(/^\/runs\/([^/]+)\/shots\/(.+)$/)
  if (runShot && req.method === 'GET') {
    const [, id, rel] = runShot
    const root = path.join(RUNS_DIR, id, 'screenshots')
    const full = path.join(root, decodeURIComponent(rel))
    if (!full.startsWith(root) || !fs.existsSync(full)) { res.writeHead(404); res.end('not found'); return }
    res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=300' })
    fs.createReadStream(full).pipe(res); return
  }
  // Frozen story step asset (image OR captured HTML)
  const storyShot = p.match(/^\/runs\/([^/]+)\/story\/([^/]+)\/(.+)$/)
  if (storyShot && req.method === 'GET') {
    const [, id, storyPath, rel] = storyShot
    const root = path.join(RUNS_DIR, id, 'story', decodeURIComponent(storyPath))
    const full = path.join(root, decodeURIComponent(rel))
    if (!full.startsWith(root) || !fs.existsSync(full)) { res.writeHead(404); res.end('not found'); return }
    const ct = full.endsWith('.html') ? 'text/html; charset=utf-8'
             : full.endsWith('.json') ? 'application/json'
             : 'image/png'
    res.writeHead(200, { 'Content-Type': ct, 'Cache-Control': 'public, max-age=300' })
    fs.createReadStream(full).pipe(res); return
  }

  res.writeHead(404); res.end('not found')
})

server.listen(PORT, () => {
  console.log(`Ask · review dashboard → http://localhost:${PORT}`)
})
