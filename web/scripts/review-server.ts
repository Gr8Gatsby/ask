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

function startRun(spec: string): Run | null {
  if (currentRunId) return null
  const run: Run = {
    id: newRunId(),
    spec,
    startedAt: Date.now(),
    endedAt: null,
    exitCode: null,
    screenshotCount: 0,
    status: 'running',
    review: null,
    gitHead: currentGitHead(),
  }
  fs.mkdirSync(path.join(RUNS_DIR, run.id), { recursive: true })
  saveRuns([run, ...loadRuns()])
  currentRunId = run.id
  currentOutput = ''
  broadcast('started', { id: run.id })

  const args = ['playwright', 'test']
  if (spec) args.push(spec)
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

interface FrozenStep { idx: number; title: string; description?: string; name?: string; file: string; durationMs: number }
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
  header { position: sticky; top: 0; z-index: 20; padding: 12px 16px; background: var(--header); border-bottom: 1px solid var(--header-bd); display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  header h1 { font-size: 14px; margin: 0; font-weight: 600; }
  header h1 a { color: inherit; text-decoration: none; }
  header .right { margin-left: auto; display: flex; gap: 8px; align-items: center; }
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
  main { padding: 16px; max-width: 1400px; margin: 0 auto; }
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
  /* Run summary header */
  .run-hero h1 { margin: 0 0 4px; font-size: 22px; line-height: 1.25; }
  .run-hero p.lead { margin: 0 0 8px; color: var(--muted); font-size: 14px; line-height: 1.55; }
  .run-hero .meta { color: var(--muted); font-size: 12px; }
  /* ----- Sticky mini-map flowchart -----
     Dot color now means "where you are":
       - default grey   = step you haven't viewed
       - blue ring      = step you're on
       - dark           = step you already passed
     A separate small badge by the number indicates feedback count, so
     "I left a note here" is no longer confused with "I'm here". */
  .mini-map { position: sticky; top: 53px; z-index: 15; background: var(--bg); padding: 10px 0 12px; border-bottom: 1px solid var(--border); margin: 8px 0 16px; }
  .mini-map .label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; margin-bottom: 8px; }
  .mini-map .nodes { display: flex; gap: 0; align-items: stretch; overflow-x: auto; padding-bottom: 2px; }
  .mini-map .node { flex: 1 1 0; min-width: 80px; display: flex; flex-direction: column; align-items: center; cursor: pointer; padding: 4px; border-radius: 6px; position: relative; }
  .mini-map .node:hover { background: var(--row-hover); }
  .mini-map .node .dot { width: 26px; height: 26px; border-radius: 50%; background: var(--dot); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 700; transition: transform .12s ease, box-shadow .12s ease, background .12s ease; }
  .mini-map .node.passed .dot { background: var(--muted); }
  .mini-map .node.current .dot { background: var(--primary); box-shadow: 0 0 0 4px rgba(0,102,204,0.22); transform: scale(1.08); }
  .mini-map .node .cap { font-size: 11px; color: var(--text); margin-top: 5px; max-width: 110px; text-align: center; line-height: 1.25; }
  .mini-map .node.current .cap { font-weight: 600; }
  .mini-map .node .fb-count { position: absolute; top: 0; right: 18%; min-width: 16px; height: 16px; padding: 0 4px; border-radius: 8px; background: var(--success); color: #fff; font-size: 10px; font-weight: 700; display: flex; align-items: center; justify-content: center; border: 2px solid var(--bg); }
  .mini-map .arrow { flex: 0 0 22px; align-self: center; height: 2px; background: var(--rail); margin-top: 13px; }
  /* ----- Slide (one step at a time) ----- */
  .story-info { padding: 14px 18px; }
  .story-info h2 { font-size: 14px; margin: 0 0 4px; }
  .story-info .desc { color: var(--muted); font-size: 13px; margin: 0; line-height: 1.55; }
  .slide { padding: 22px 22px 18px; }
  .slide .step-meta { color: var(--muted); font-size: 12px; margin: 0 0 4px; }
  .slide .step-title { font-size: 18px; font-weight: 600; margin: 0 0 6px; }
  .slide .step-desc { color: var(--muted); font-size: 14px; line-height: 1.6; margin: 0 0 16px; max-width: 760px; }
  .slide .step-shot-wrap { display: flex; justify-content: center; background: var(--code-bg); border: 1px solid var(--border); border-radius: 8px; padding: 18px; margin-bottom: 16px; }
  .slide .step-shot { max-width: 100%; max-height: 720px; cursor: zoom-in; border-radius: 4px; }
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
  /* ----- Prev / Next nav under the slide ----- */
  .slide-nav { display: flex; justify-content: space-between; gap: 12px; margin: 18px 0 0; }
  .slide-nav button { padding: 9px 16px; display: inline-flex; align-items: center; gap: 6px; font-size: 14px; }
  .slide-nav button svg { width: 16px; height: 16px; }
  .slide-nav button:disabled { visibility: hidden; }
  .slide-nav .step-counter { color: var(--muted); font-size: 12px; align-self: center; }
  /* ----- Sticky review form pinned to the bottom ----- */
  .review-sticky { position: sticky; bottom: 0; z-index: 14; background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; margin: 24px 0 0; box-shadow: 0 -4px 14px rgba(0,0,0,0.06); }
  [data-theme="dark"] .review-sticky { box-shadow: 0 -4px 14px rgba(0,0,0,0.3); }
  .review-sticky .head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; flex-wrap: wrap; margin-bottom: 8px; }
  .review-sticky .head h3 { margin: 0; font-size: 13px; color: var(--muted); }
  .review-sticky textarea { min-height: 50px; }
  .review-sticky .row { margin-top: 8px; }
  .review-sticky .help { color: var(--muted); font-size: 11px; margin-top: 6px; line-height: 1.5; }
  /* Lightbox */
  dialog { background: rgba(0,0,0,0.92); border: none; max-width: 100vw; max-height: 100vh; padding: 0; }
  dialog img { max-width: 100vw; max-height: 100vh; display: block; cursor: zoom-out; }
  dialog::backdrop { background: rgba(0,0,0,0.85); }
  /* Misc */
  .muted { color: var(--muted); font-size: 12px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 12px; }
  figure { margin: 0; background: var(--panel); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; box-shadow: var(--shadow); }
  figure img { display: block; width: 100%; cursor: zoom-in; background: var(--code-bg); }
  figcaption { padding: 7px 10px; font-size: 11px; color: var(--muted); display: flex; justify-content: space-between; border-top: 1px solid var(--border); }
</style>
</head>
<body data-theme="light">
<header>
  <h1><a href="#/">Ask · review</a></h1>
  <span id="status" class="badge">idle</span>
  <div class="right">
    <select id="spec"><option value="">All specs</option></select>
    <button id="run" class="primary">New run</button>
    <button id="theme-toggle" class="icon-only" title="Toggle light/dark"></button>
    <a href="http://localhost:5173/dev/markdown" target="_blank"><button>/dev/markdown ↗</button></a>
    <a href="http://localhost:5173/" target="_blank"><button>app ↗</button></a>
  </div>
</header>
<main id="view"></main>
<dialog id="lightbox"><img alt=""></dialog>
<script>
// Inline SVGs (Heroicons outline, 24x24 viewBox, stroke=currentColor).
// No network dependency, scales cleanly, inherits the button text color.
const SVG = {
  ok:        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/></svg>',
  bug:       '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 12.75c1.148 0 2.278.08 3.383.237 1.037.146 1.866.966 1.866 2.013 0 3.728-2.35 6.75-5.25 6.75S6.75 18.728 6.75 15c0-1.046.83-1.867 1.866-2.013A24.16 24.16 0 0 1 12 12.75ZM12 9.75v.008M12 6.75v6M9 6.75 7.5 5.25M15 6.75l1.5-1.5M9 12.75H6M15 12.75h3M5.25 18.75H4.5M19.5 18.75H18.75"/></svg>',
  style:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9.53 16.122a3 3 0 0 0-3.412 1.034c-.473.658-.892 1.4-1.218 2.193a39.4 39.4 0 0 0 3.279-.764 3 3 0 0 0 1.351-2.463zM3.75 12.75A8.967 8.967 0 0 1 12 4.5c5 0 8.25 3.75 8.25 8.25 0 4-2 6-3 7l-3-3c1-1 3-3 3-7"/><path d="M14.25 9.75 10 14"/></svg>',
  copy:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M16.862 4.487 18.549 2.799a2.121 2.121 0 1 1 3 3L19.862 7.487m-3-3L6.832 14.518a4.5 4.5 0 0 0-1.13 1.897l-1.034 3.45 3.45-1.034a4.5 4.5 0 0 0 1.897-1.13L19.862 7.487m-3-3 3 3"/></svg>',
  confusing: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9.879 7.519c1.171-1.025 3.071-1.025 4.242 0 1.172 1.025 1.172 2.687 0 3.712-.203.179-.43.326-.67.442-.745.361-1.45.999-1.45 1.827v.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 5.25h.008v.008H12v-.008Z"/></svg>',
  slow:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"/></svg>',
  other:     '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.25 12.76c0 1.6 1.123 2.994 2.707 3.227 1.068.157 2.148.279 3.238.364.466.037.893.281 1.153.671L12 21l2.652-3.978c.26-.39.687-.634 1.153-.67 1.09-.086 2.17-.208 3.238-.365 1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"/></svg>',
  remove:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 18 18 6M6 6l12 12"/></svg>',
  sun:       '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M5.05 5.05l1.41 1.41M17.54 17.54l1.41 1.41M3 12h2M19 12h2M5.05 18.95l1.41-1.41M17.54 6.46l1.41-1.41"/></svg>',
  moon:      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>',
  arrowLeft: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5M12 19l-7-7 7-7"/></svg>',
  arrowRight:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12h14M12 5l7 7-7 7"/></svg>',
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
const statusEl = document.getElementById('status');
const lightbox = document.getElementById('lightbox');
const lightboxImg = lightbox.querySelector('img');
lightboxImg.addEventListener('click', () => lightbox.close());
lightbox.addEventListener('click', (e) => { if (e.target === lightbox) lightbox.close(); });

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
async function renderDetail(id) {
  const r = await fetch('/api/runs/' + id).then(r => r.json());
  if (r.error) { view.innerHTML = '<div class="empty">Run not found.</div>'; return; }
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

  // ----- review form (rendered separately, pinned to bottom) -----
  let reviewBody = '';
  if (r.review) {
    reviewBody = '<div class="head"><h3>Reviewed · <span class="decision-' + r.review.decision + '">' + r.review.decision + '</span> · ' + ago(r.review.reviewedAt) + '</h3>' +
      '<button id="reopen">Reopen</button></div>' +
      '<p style="margin:0;white-space:pre-wrap;font-size:13px">' + escape(r.review.summary || '(no summary)') + '</p>';
  } else if (r.status !== 'running') {
    reviewBody = '<div class="head"><h3>Overall review</h3>' +
      '<span class="muted">Use per-step tags above for specifics; only the overall decision is required to finalize.</span></div>' +
      '<textarea id="summary" placeholder="Optional — anything global to call out? (per-step quick-tags above replace most typing)"></textarea>' +
      '<div class="row">' +
        '<button class="success" data-decision="approved">Approve</button>' +
        '<button data-decision="changes-requested">Changes requested</button>' +
        '<button class="danger" data-decision="rejected">Reject</button>' +
      '</div>' +
      '<p class="help"><strong>Approve</strong> = stop nagging unless web/src or ask/scripts changes. ' +
        '<strong>Changes / Reject</strong> = log as known-not-ready, suppress stale alerts. ' +
        'Submitting never re-runs the test — that\\'s always explicit via <em>New run</em>.</p>';
  }

  // ----- mini-map flowchart (sticky) -----
  let miniMap = '';
  if (allSteps.length) {
    miniMap = '<div class="mini-map" id="mini-map"><div class="label">Where you are</div><div class="nodes">' +
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
    slideHtml =
      (stories.length === 1
        ? '<div class="story-info panel" style="margin-top:0;margin-bottom:0;border-bottom-left-radius:0;border-bottom-right-radius:0;border-bottom:0">' +
            '<h2>' + escape(s.title || s.testTitle) + '</h2>' +
            (s.description ? '<p class="desc">' + escape(s.description) + '</p>' : '') +
          '</div>'
        : '') +
      '<div class="panel slide" style="margin-top:' + (stories.length === 1 ? '0' : '16px') + ';border-top-left-radius:' + (stories.length === 1 ? '0' : '8px') + ';border-top-right-radius:' + (stories.length === 1 ? '0' : '8px') + '" data-story-path="' + escape(s.path) + '" data-step="' + st.idx + '">' +
        '<p class="step-meta">Step ' + (slideIdx+1) + ' of ' + allSteps.length + ' · ' + st.durationMs + 'ms</p>' +
        '<h2 class="step-title">' + escape(st.title) + '</h2>' +
        (st.description ? '<p class="step-desc">' + escape(st.description) + '</p>' : '') +
        (st.file ? '<div class="step-shot-wrap"><img class="step-shot" src="/runs/' + r.id + '/story/' + encodeURI(s.path) + '/' + encodeURI(st.file) + '" alt="' + escape(st.title) + '"></div>' : '') +
        '<div class="quick">' +
          KINDS.map(k => '<button data-kind="' + k.id + '">' + k.icon + '<span>' + k.label + '</span></button>').join('') +
          '<button data-kind="other">' + SVG.other + '<span>Comment</span></button>' +
        '</div>' +
        '<div class="fb-list">' +
          stepFb.map(f => '<div class="fb-row">' +
            '<span class="kind">' + (KINDS.find(k=>k.id===f.kind)?.icon ?? SVG.other) + escape(f.kind) + '</span>' +
            '<span class="text">' + escape(f.text || '') + '</span>' +
            '<span class="x" data-at="' + f.at + '" title="remove">' + SVG.remove + '</span>' +
          '</div>').join('') +
        '</div>' +
        '<div class="slide-nav">' +
          '<button id="prev"' + (slideIdx === 0 ? ' disabled' : '') + '>' + SVG.arrowLeft + '<span>Previous</span></button>' +
          '<span class="step-counter">' + (slideIdx+1) + ' / ' + allSteps.length + '   ·   ← / → to navigate</span>' +
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

  // ----- friendly hero -----
  const primaryStory = stories[0];
  const heroTitle = primaryStory?.title || (r.spec || '(all specs)').replace(/^e2e\\//, '').replace(/\\.spec\\.ts$/, '');
  const heroDesc = primaryStory?.description || '';

  view.innerHTML =
    '<p style="margin:0 0 12px"><a href="#/">← all runs</a></p>' +
    '<div class="run-hero">' +
      '<h1>' + escape(heroTitle) + '</h1>' +
      (heroDesc ? '<p class="lead">' + escape(heroDesc) + '</p>' : '') +
      '<p class="meta">' + escape(r.spec || '(all specs)').replace(/^e2e\\//,'') + ' · ' + r.id + ' · started ' + ago(r.startedAt) + ' · ' + passedBadge + staleBadge + '</p>' +
    '</div>' +
    miniMap +
    slideHtml +
    shotsHtml +
    (reviewBody ? '<div class="review-sticky" id="review-sticky">' + reviewBody + '</div>' : '') +
    '<details' + (r.exitCode === 0 ? '' : ' open') + ' style="margin-top:16px"><summary style="cursor:pointer" class="muted">Output</summary>' +
      '<pre class="output" id="run-output">' + escape(r.output ?? '') + '</pre></details>';

  // image lightbox
  view.querySelectorAll('img.step-shot, figure img').forEach(img => {
    img.addEventListener('click', () => { lightboxImg.src = img.src; lightbox.showModal(); });
  });

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
  // per-step quick-tag handlers (slide is the active step container)
  const slideEl = view.querySelector('.slide');
  if (slideEl) {
    const storyPath = slideEl.dataset.storyPath;
    const stepIdx = parseInt(slideEl.dataset.step, 10);
    slideEl.querySelectorAll('button[data-kind]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const kind = btn.dataset.kind;
        let text = '';
        if (kind === 'other' || kind === 'bug' || kind === 'confusing') {
          text = prompt('Add a note (optional):') ?? '';
          if (kind === 'other' && !text) return;
        }
        await fetch('/api/runs/' + r.id + '/feedback', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ storyPath, stepIdx, kind, text }),
        });
        renderDetail(r.id);
      });
    });
    slideEl.querySelectorAll('.fb-row .x').forEach(x => {
      x.addEventListener('click', async () => {
        const at = parseInt(x.dataset.at, 10);
        await fetch('/api/runs/' + r.id + '/feedback?at=' + at, { method: 'DELETE' });
        renderDetail(r.id);
      });
    });
  }
}

// ---------- routing -------------------------------------------------------
function route() {
  const m = location.hash.match(/^#\\/run\\/(.+)$/);
  if (m) renderDetail(m[1]); else renderList();
}
window.addEventListener('hashchange', route);

// ---------- run controls --------------------------------------------------
runEl.addEventListener('click', async () => {
  const r = await fetch('/api/run', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ spec: specEl.value }),
  }).then(r => r.json());
  if (r.id) location.hash = '#/run/' + r.id;
});

const es = new EventSource('/api/output');
es.addEventListener('started', () => { statusEl.textContent = 'running…'; statusEl.className = 'badge running'; runEl.disabled = true; });
es.addEventListener('line', (e) => {
  const out = document.getElementById('run-output');
  if (out) { out.textContent += JSON.parse(e.data).line; out.scrollTop = out.scrollHeight; }
});
es.addEventListener('done', () => {
  statusEl.textContent = 'idle'; statusEl.className = 'badge';
  runEl.disabled = false;
  route();
});

// ---------- theme toggle (light by default, persisted) -------------------
const themeBtn = document.getElementById('theme-toggle');
function applyTheme(t) {
  document.body.dataset.theme = t;
  themeBtn.innerHTML = t === 'dark' ? SVG.sun : SVG.moon;
  themeBtn.title = t === 'dark' ? 'Switch to light' : 'Switch to dark';
}
applyTheme(localStorage.getItem('ask-review-theme') || 'light');
themeBtn.addEventListener('click', () => {
  const next = document.body.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('ask-review-theme', next);
  applyTheme(next);
});

loadSpecs();
route();
setInterval(() => { if (!location.hash.startsWith('#/run/')) renderList(); }, 5000);
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
    res.end(JSON.stringify({
      ...r,
      output,
      screenshots: listFrozenShots(r.id),
      stories: listFrozenStories(r.id),
      feedback: loadFeedback(r.id),
      stale: isPotentiallyStale(r),
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
        const { storyPath, stepIdx, kind, text } = JSON.parse(body) as Omit<Feedback, 'at'>
        const fb = loadFeedback(feedback[1])
        fb.push({ storyPath, stepIdx, kind, text: text || '', at: Date.now() })
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
  // Frozen story step image
  const storyShot = p.match(/^\/runs\/([^/]+)\/story\/([^/]+)\/(.+)$/)
  if (storyShot && req.method === 'GET') {
    const [, id, storyPath, rel] = storyShot
    const root = path.join(RUNS_DIR, id, 'story', decodeURIComponent(storyPath))
    const full = path.join(root, decodeURIComponent(rel))
    if (!full.startsWith(root) || !fs.existsSync(full)) { res.writeHead(404); res.end('not found'); return }
    res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=300' })
    fs.createReadStream(full).pipe(res); return
  }

  res.writeHead(404); res.end('not found')
})

server.listen(PORT, () => {
  console.log(`Ask · review dashboard → http://localhost:${PORT}`)
})
