/**
 * Ask · review dashboard
 *
 * Landing page: every test run as a row (status, spec, time, shots, review note).
 * Click a run → frozen screenshots, run output, and a review form to mark it
 * reviewed with a summary + decision.
 *
 * Data lives under web/.review/:
 *   runs.json                    – array of run metadata (newest first)
 *   runs/<id>/output.txt         – captured stdout/stderr
 *   runs/<id>/screenshots/...    – frozen copy of the screenshots that PR
 *                                  produced (so historical runs survive
 *                                  re-runs that overwrite e2e/screenshots/)
 *
 * Run with: cd web && npm run review   →   http://localhost:4244
 */
import http from 'http'
import fs from 'fs'
import path from 'path'
import { spawn } from 'child_process'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const WEB = path.resolve(__dirname, '..')
const SHOTS = path.join(WEB, 'e2e', 'screenshots')
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
interface Run {
  id: string
  spec: string                  // '' = all specs
  startedAt: number
  endedAt: number | null
  exitCode: number | null
  screenshotCount: number
  status: 'running' | 'awaiting-review' | 'reviewed'
  review: Review | null
}

function loadRuns(): Run[] {
  try { return JSON.parse(fs.readFileSync(RUNS_JSON, 'utf-8')) as Run[] }
  catch { return [] }
}
function saveRuns(runs: Run[]) {
  fs.writeFileSync(RUNS_JSON, JSON.stringify(runs, null, 2))
}
function getRun(id: string): Run | undefined {
  return loadRuns().find(r => r.id === id)
}
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
  const dest = path.join(RUNS_DIR, runId, 'screenshots')
  fs.mkdirSync(dest, { recursive: true })
  let n = 0
  for (const src of listShots(SHOTS)) {
    const st = fs.statSync(src)
    if (st.mtimeMs < since) continue
    const rel = path.relative(SHOTS, src)
    const dst = path.join(dest, rel)
    fs.mkdirSync(path.dirname(dst), { recursive: true })
    fs.copyFileSync(src, dst)
    n++
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
  select:hover, button:hover { background: #222226; }
  button.primary { background: #0066cc; border-color: #0066cc; color: #fff; }
  button.primary:hover { background: #0077ee; }
  button.danger { background: #6b1a1a; border-color: #6b1a1a; color: #fff; }
  button.success { background: #1d6f1d; border-color: #1d6f1d; color: #fff; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  main { padding: 16px; }
  .group { margin-bottom: 24px; }
  .group h2 { font-size: 12px; color: #888; text-transform: uppercase; letter-spacing: 0.06em; margin: 0 0 8px; font-weight: 600; }
  table { width: 100%; border-collapse: collapse; }
  table th, table td { padding: 10px 12px; text-align: left; border-bottom: 1px solid #1f1f22; vertical-align: top; }
  table th { font-size: 11px; color: #888; text-transform: uppercase; letter-spacing: 0.06em; font-weight: 600; }
  table tr:hover td { background: #14141a; }
  table tr.clickable { cursor: pointer; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 12px; }
  figure { margin: 0; background: #131316; border: 1px solid #262629; border-radius: 8px; overflow: hidden; }
  figure img { display: block; width: 100%; cursor: zoom-in; background: #000; }
  figcaption { padding: 6px 10px; font-size: 11px; color: #999; display: flex; justify-content: space-between; }
  pre.output { background: #0a0a0c; border: 1px solid #2a2a2a; border-radius: 6px; padding: 10px; max-height: 280px; overflow: auto; font: 11px/1.4 ui-monospace,monospace; white-space: pre-wrap; }
  .empty { color: #666; padding: 28px; text-align: center; }
  .badge { padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; display: inline-block; }
  .badge.running { background: #0a4d0a; color: #afe9af; }
  .badge.awaiting { background: #4d3d0a; color: #f5d77a; }
  .badge.reviewed { background: #0a3a4d; color: #a4d8ee; }
  .badge.passed { background: #0a4d0a; color: #afe9af; }
  .badge.failed { background: #4d0a0a; color: #ee9c9c; }
  .decision-approved { color: #afe9af; }
  .decision-changes-requested { color: #f5d77a; }
  .decision-rejected { color: #ee9c9c; }
  a { color: #4aa3ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
  textarea { width: 100%; min-height: 80px; resize: vertical; font-family: inherit; }
  .review-form { background: #131316; border: 1px solid #262629; border-radius: 8px; padding: 14px; margin: 16px 0; }
  .review-form .row { display: flex; gap: 10px; align-items: center; margin-top: 10px; }
  .review-existing { background: #131316; border: 1px solid #262629; border-radius: 8px; padding: 14px; margin: 16px 0; }
  .review-existing h3 { margin: 0 0 6px; font-size: 13px; color: #aaa; }
  .review-existing p { margin: 0; white-space: pre-wrap; }
  /* Lightbox */
  dialog { background: rgba(0,0,0,0.95); border: none; max-width: 100vw; max-height: 100vh; padding: 0; }
  dialog img { max-width: 100vw; max-height: 100vh; display: block; cursor: zoom-out; }
  dialog::backdrop { background: rgba(0,0,0,0.9); }
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
    const passed = r.exitCode === 0;
    const exitBadge = r.exitCode === null
      ? '<span class="badge running">running</span>'
      : passed ? '<span class="badge passed">passed</span>'
               : '<span class="badge failed">failed</span>';
    const statusBadge = '<span class="badge ' + (
      r.status === 'running' ? 'running' :
      r.status === 'reviewed' ? 'reviewed' :
      'awaiting'
    ) + '">' + r.status + '</span>';
    const decision = r.review
      ? '<span class="decision-' + r.review.decision + '">' + r.review.decision + '</span> · ' + escape(r.review.summary).slice(0, 80)
      : '—';
    return '<tr class="clickable" data-id="' + r.id + '">' +
      '<td>' + ago(r.startedAt) + '<br><span style="color:#666;font-size:11px">' + r.id + '</span></td>' +
      '<td>' + escape(r.spec || '(all specs)').replace(/^e2e\\//,'') + '</td>' +
      '<td>' + exitBadge + '</td>' +
      '<td>' + statusBadge + '</td>' +
      '<td>' + r.screenshotCount + '</td>' +
      '<td>' + decision + '</td>' +
    '</tr>';
  }).join('');
  view.innerHTML =
    '<table>' +
      '<thead><tr><th>When</th><th>Spec</th><th>Result</th><th>Review</th><th>Shots</th><th>Decision · Summary</th></tr></thead>' +
      '<tbody>' + rows + '</tbody>' +
    '</table>';
  view.querySelectorAll('tr.clickable').forEach(tr => {
    tr.addEventListener('click', () => location.hash = '#/run/' + tr.dataset.id);
  });
}

// ---------- detail view ---------------------------------------------------
async function renderDetail(id) {
  const r = await fetch('/api/runs/' + id).then(r => r.json());
  if (r.error) { view.innerHTML = '<div class="empty">Run not found.</div>'; return; }
  const passedBadge = r.exitCode === null
    ? '<span class="badge running">running</span>'
    : r.exitCode === 0 ? '<span class="badge passed">passed</span>' : '<span class="badge failed">failed</span>';

  let reviewSection = '';
  if (r.review) {
    reviewSection = '<div class="review-existing">' +
      '<h3>Review · <span class="decision-' + r.review.decision + '">' + r.review.decision + '</span> · ' + ago(r.review.reviewedAt) + '</h3>' +
      '<p>' + escape(r.review.summary) + '</p>' +
      '<div class="row"><button id="reopen">Reopen</button></div>' +
    '</div>';
  } else if (r.status !== 'running') {
    reviewSection = '<div class="review-form">' +
      '<h3 style="margin:0 0 8px;font-size:13px;color:#aaa">Mark this run reviewed</h3>' +
      '<textarea id="summary" placeholder="What did you decide? What needs follow-up?"></textarea>' +
      '<div class="row">' +
        '<button class="success" data-decision="approved">Approve</button>' +
        '<button data-decision="changes-requested">Changes requested</button>' +
        '<button class="danger" data-decision="rejected">Reject</button>' +
      '</div>' +
    '</div>';
  }

  const shotGroups = new Map();
  for (const s of r.screenshots) {
    const parts = s.rel.split('/');
    const g = parts.length > 1 ? parts[0] : '(root)';
    if (!shotGroups.has(g)) shotGroups.set(g, []);
    shotGroups.get(g).push(s);
  }
  let shotsHtml = '';
  if (!r.screenshots.length) {
    shotsHtml = '<div class="empty">This run captured no screenshots.</div>';
  } else {
    for (const [g, items] of shotGroups) {
      shotsHtml += '<div class="group"><h2>' + escape(g) + ' — ' + items.length + '</h2><div class="grid">' +
        items.map(s =>
          '<figure><img loading="lazy" src="/runs/' + r.id + '/shots/' + encodeURI(s.rel) + '" alt="' + escape(s.rel) + '" />' +
          '<figcaption><span>' + escape(s.rel.split("/").pop()) + '</span><span>' + fmt(s.size) + '</span></figcaption></figure>'
        ).join('') + '</div></div>';
    }
  }

  view.innerHTML =
    '<p style="margin:0 0 12px"><a href="#/">← all runs</a></p>' +
    '<h2 style="margin:0 0 4px;font-size:16px">' + escape(r.spec || '(all specs)').replace(/^e2e\\//,'') + '</h2>' +
    '<p style="margin:0 0 14px;color:#888;font-size:12px">' + r.id + ' · started ' + ago(r.startedAt) + ' · ' + passedBadge + '</p>' +
    reviewSection +
    '<details' + (r.exitCode === 0 ? '' : ' open') + '><summary style="cursor:pointer;color:#888;margin:8px 0;font-size:12px">Output</summary>' +
      '<pre class="output" id="run-output">' + escape(r.output ?? '') + '</pre>' +
    '</details>' +
    shotsHtml;

  view.querySelectorAll('figure img').forEach(img => {
    img.addEventListener('click', () => { lightboxImg.src = img.src; lightbox.showModal(); });
  });
  view.querySelectorAll('button[data-decision]').forEach(b => {
    b.addEventListener('click', async () => {
      const summary = (document.getElementById('summary')).value.trim() || '(no notes)';
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
  route();   // reload current view (list or detail) so new shots appear
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
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(loadRuns())); return
  }

  const runDetail = p.match(/^\/api\/runs\/([^/]+)$/)
  if (runDetail && req.method === 'GET') {
    const r = getRun(runDetail[1])
    if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
    const outputPath = path.join(RUNS_DIR, r.id, 'output.txt')
    const output = fs.existsSync(outputPath) ? fs.readFileSync(outputPath, 'utf-8')
                  : (currentRunId === r.id ? currentOutput : '')
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ...r, output, screenshots: listFrozenShots(r.id) })); return
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
          review: { summary, decision, reviewedAt: Date.now() },
        })
        if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
        res.writeHead(200, { 'Content-Type': 'application/json' })
        res.end(JSON.stringify(r))
      } catch (e) {
        res.writeHead(400); res.end(JSON.stringify({ error: String(e) }))
      }
    })
    return
  }

  if (review && req.method === 'DELETE') {
    const r = updateRun(review[1], { status: 'awaiting-review', review: null })
    if (!r) { res.writeHead(404); res.end(JSON.stringify({ error: 'not found' })); return }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(r)); return
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

  const runShot = p.match(/^\/runs\/([^/]+)\/shots\/(.+)$/)
  if (runShot && req.method === 'GET') {
    const [, id, rel] = runShot
    const full = path.join(RUNS_DIR, id, 'screenshots', decodeURIComponent(rel))
    const root = path.join(RUNS_DIR, id, 'screenshots')
    if (!full.startsWith(root) || !fs.existsSync(full)) { res.writeHead(404); res.end('not found'); return }
    res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=300' })
    fs.createReadStream(full).pipe(res); return
  }

  res.writeHead(404); res.end('not found')
})

server.listen(PORT, () => {
  console.log(`Ask · review dashboard → http://localhost:${PORT}`)
})
