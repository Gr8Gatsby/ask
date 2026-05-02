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

interface FrozenStory { path: string; testTitle: string; steps: { idx: number; name: string; file: string; durationMs: number }[] }
function listFrozenStories(runId: string): FrozenStory[] {
  const root = path.join(RUNS_DIR, runId, 'story')
  if (!fs.existsSync(root)) return []
  const out: FrozenStory[] = []
  for (const e of fs.readdirSync(root, { withFileTypes: true })) {
    if (!e.isDirectory()) continue
    const j = path.join(root, e.name, 'story.json')
    if (!fs.existsSync(j)) continue
    try {
      const data = JSON.parse(fs.readFileSync(j, 'utf-8')) as { testTitle?: string; steps: FrozenStory['steps'] }
      out.push({ path: e.name, testTitle: data.testTitle ?? e.name, steps: data.steps ?? [] })
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
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #0b0b0c; color: #eee; }
  header { position: sticky; top: 0; z-index: 10; padding: 12px 16px; background: #111; border-bottom: 1px solid #2a2a2a; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  header h1 { font-size: 14px; margin: 0; font-weight: 600; }
  header h1 a { color: inherit; text-decoration: none; }
  header .right { margin-left: auto; display: flex; gap: 8px; align-items: center; }
  select, button, input, textarea { background: #1a1a1c; color: #eee; border: 1px solid #333; border-radius: 6px; padding: 6px 10px; font: inherit; }
  button { cursor: pointer; }
  select:hover, button:hover:not(:disabled) { background: #222226; }
  button.primary { background: #0066cc; border-color: #0066cc; color: #fff; }
  button.primary:hover { background: #0077ee; }
  button.danger { background: #6b1a1a; border-color: #6b1a1a; color: #fff; }
  button.success { background: #1d6f1d; border-color: #1d6f1d; color: #fff; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  main { padding: 16px; max-width: 1400px; margin: 0 auto; }
  table { width: 100%; border-collapse: collapse; }
  table th, table td { padding: 10px 12px; text-align: left; border-bottom: 1px solid #1f1f22; vertical-align: top; }
  table th { font-size: 11px; color: #888; text-transform: uppercase; letter-spacing: 0.06em; font-weight: 600; }
  table tr:hover td { background: #14141a; }
  table tr.clickable { cursor: pointer; }
  .empty { color: #666; padding: 28px; text-align: center; }
  .badge { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; display: inline-block; }
  .badge.running { background: #0a4d0a; color: #afe9af; }
  .badge.awaiting { background: #4d3d0a; color: #f5d77a; }
  .badge.reviewed { background: #0a3a4d; color: #a4d8ee; }
  .badge.passed { background: #0a4d0a; color: #afe9af; }
  .badge.failed { background: #4d0a0a; color: #ee9c9c; }
  .badge.stale { background: #6b1a1a; color: #ffc9c9; }
  .decision-approved { color: #afe9af; }
  .decision-changes-requested { color: #f5d77a; }
  .decision-rejected { color: #ee9c9c; }
  a { color: #4aa3ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
  textarea { width: 100%; min-height: 60px; resize: vertical; font-family: inherit; }
  pre.output { background: #0a0a0c; border: 1px solid #2a2a2a; border-radius: 6px; padding: 10px; max-height: 280px; overflow: auto; font: 11px/1.4 ui-monospace,monospace; white-space: pre-wrap; }
  .panel { background: #131316; border: 1px solid #262629; border-radius: 8px; padding: 14px; margin: 16px 0; }
  .panel h3 { margin: 0 0 8px; font-size: 13px; color: #aaa; }
  .panel .row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
  .panel .help { color: #777; font-size: 12px; margin-top: 8px; line-height: 1.5; }
  /* Story timeline */
  .story h2 { font-size: 12px; color: #888; text-transform: uppercase; margin: 0 0 8px; }
  .timeline { position: relative; padding-left: 32px; }
  .timeline::before { content: ""; position: absolute; left: 12px; top: 6px; bottom: 6px; width: 2px; background: #262629; }
  .step { position: relative; margin-bottom: 18px; }
  .step::before { content: ""; position: absolute; left: -26px; top: 6px; width: 12px; height: 12px; border-radius: 50%; background: #444; border: 2px solid #131316; }
  .step.has-fb::before { background: #4aa3ff; }
  .step .head { display: flex; gap: 8px; align-items: baseline; flex-wrap: wrap; }
  .step .num { color: #666; font-size: 12px; font-family: ui-monospace, monospace; }
  .step .name { font-weight: 500; }
  .step .duration { color: #666; font-size: 11px; }
  .step .shot { display: block; margin-top: 8px; max-width: 720px; width: 100%; border: 1px solid #262629; border-radius: 6px; cursor: zoom-in; }
  .step .quick { margin-top: 6px; display: flex; gap: 4px; flex-wrap: wrap; }
  .step .quick button { font-size: 12px; padding: 3px 8px 3px 6px; display: inline-flex; align-items: center; gap: 5px; }
  .step .quick button svg { width: 14px; height: 14px; flex-shrink: 0; opacity: 0.85; }
  .step .quick button.active { background: #4aa3ff; border-color: #4aa3ff; color: #fff; }
  .step .fb { margin-top: 6px; }
  .step .fb-list { margin-top: 6px; display: flex; flex-direction: column; gap: 4px; }
  .step .fb-row { background: #1a1a1c; border: 1px solid #262629; border-radius: 4px; padding: 6px 8px; font-size: 12px; display: flex; gap: 8px; align-items: flex-start; }
  .step .fb-row .kind { font-weight: 600; min-width: 80px; display: inline-flex; align-items: center; gap: 4px; }
  .step .fb-row .kind svg { width: 13px; height: 13px; flex-shrink: 0; opacity: 0.85; }
  .step .fb-row .text { color: #ddd; flex: 1; }
  .step .fb-row .x { color: #666; cursor: pointer; display: inline-flex; align-items: center; }
  .step .fb-row .x svg { width: 13px; height: 13px; }
  .step .fb-row .x:hover { color: #ee9c9c; }
  /* Lightbox */
  dialog { background: rgba(0,0,0,0.95); border: none; max-width: 100vw; max-height: 100vh; padding: 0; }
  dialog img { max-width: 100vw; max-height: 100vh; display: block; cursor: zoom-out; }
  dialog::backdrop { background: rgba(0,0,0,0.9); }
  /* Misc */
  .muted { color: #888; font-size: 12px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 12px; }
  figure { margin: 0; background: #131316; border: 1px solid #262629; border-radius: 8px; overflow: hidden; }
  figure img { display: block; width: 100%; cursor: zoom-in; background: #000; }
  figcaption { padding: 6px 10px; font-size: 11px; color: #999; display: flex; justify-content: space-between; }
</style>
</head>
<body>
<header>
  <h1><a href="#/">Ask · review</a></h1>
  <span id="status" class="badge">idle</span>
  <div class="right">
    <select id="spec"><option value="">All specs</option></select>
    <button id="run" class="primary">New run</button>
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

  // ----- review section -----
  let reviewSection = '';
  if (r.review) {
    reviewSection = '<div class="panel">' +
      '<h3>Review · <span class="decision-' + r.review.decision + '">' + r.review.decision + '</span> · ' + ago(r.review.reviewedAt) + '</h3>' +
      '<p style="margin:0;white-space:pre-wrap">' + escape(r.review.summary || '(no summary)') + '</p>' +
      '<div class="row" style="margin-top:8px"><button id="reopen">Reopen</button></div>' +
    '</div>';
  } else if (r.status !== 'running') {
    reviewSection = '<div class="panel">' +
      '<h3>Mark this run reviewed</h3>' +
      '<textarea id="summary" placeholder="Optional — what stood out? (Per-step quick-tags below replace most typing.)"></textarea>' +
      '<div class="row" style="margin-top:8px">' +
        '<button class="success" data-decision="approved">Approve</button>' +
        '<button data-decision="changes-requested">Changes requested</button>' +
        '<button class="danger" data-decision="rejected">Reject</button>' +
      '</div>' +
      '<p class="help">' +
        '<strong>Approve</strong> → don\\'t re-prompt unless web/src or ask/scripts changes (then a "may be stale" badge appears).<br>' +
        '<strong>Changes requested / Reject</strong> → suppresses stale alerts; this run is logged as known-not-ready.<br>' +
        'Submitting never re-runs the test. Use the <em>New run</em> button when you want to retest.' +
      '</p>' +
    '</div>';
  }

  // ----- story timelines -----
  let storyHtml = '';
  for (const s of (r.stories || [])) {
    storyHtml += '<div class="story panel" data-story-path="' + escape(s.path) + '">' +
      '<h2>' + escape(s.testTitle) + ' — ' + s.steps.length + ' step' + (s.steps.length===1?'':'s') + '</h2>' +
      '<div class="timeline">' +
        s.steps.map(st => {
          const stepFb = fb.filter(x => x.storyPath === s.path && x.stepIdx === st.idx);
          return '<div class="step' + (stepFb.length ? ' has-fb' : '') + '" data-step="' + st.idx + '">' +
            '<div class="head">' +
              '<span class="num">' + String(st.idx+1).padStart(2,'0') + '</span>' +
              '<span class="name">' + escape(st.name) + '</span>' +
              '<span class="duration">· ' + st.durationMs + 'ms</span>' +
            '</div>' +
            (st.file ? '<img class="shot" loading="lazy" src="/runs/' + r.id + '/story/' + encodeURI(s.path) + '/' + encodeURI(st.file) + '" alt="' + escape(st.name) + '">' : '') +
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
          '</div>';
        }).join('') +
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

  view.innerHTML =
    '<p style="margin:0 0 12px"><a href="#/">← all runs</a></p>' +
    '<h2 style="margin:0 0 4px;font-size:16px">' + escape(r.spec || '(all specs)').replace(/^e2e\\//,'') + '</h2>' +
    '<p style="margin:0 0 14px" class="muted">' + r.id + ' · started ' + ago(r.startedAt) + ' · ' + passedBadge + staleBadge + '</p>' +
    reviewSection +
    storyHtml +
    shotsHtml +
    '<details' + (r.exitCode === 0 ? '' : ' open') + '><summary style="cursor:pointer" class="muted">Output</summary>' +
      '<pre class="output" id="run-output">' + escape(r.output ?? '') + '</pre></details>';

  // image lightbox
  view.querySelectorAll('img.shot, figure img').forEach(img => {
    img.addEventListener('click', () => { lightboxImg.src = img.src; lightbox.showModal(); });
  });
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
  // per-step quick-tag handlers
  view.querySelectorAll('.story').forEach(storyEl => {
    const storyPath = storyEl.dataset.storyPath;
    storyEl.querySelectorAll('.step').forEach(stepEl => {
      const stepIdx = parseInt(stepEl.dataset.step, 10);
      stepEl.querySelectorAll('button[data-kind]').forEach(btn => {
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
      stepEl.querySelectorAll('.fb-row .x').forEach(x => {
        x.addEventListener('click', async () => {
          const at = parseInt(x.dataset.at, 10);
          await fetch('/api/runs/' + r.id + '/feedback?at=' + at, { method: 'DELETE' });
          renderDetail(r.id);
        });
      });
    });
  });
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
