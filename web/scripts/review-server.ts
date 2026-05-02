/**
 * Tiny review dashboard for the e2e screenshots + test runs.
 *
 * Start with: cd web && npm run review
 *
 * Serves:
 *   GET  /                       → HTML dashboard (auto-refreshes when shots change)
 *   GET  /api/screenshots        → JSON listing of e2e/screenshots/**
 *   GET  /api/specs              → JSON listing of e2e/*.spec.ts
 *   POST /api/run                → body: { spec: string | "" }   →  runs playwright test
 *   GET  /api/output             → SSE stream of the most recent run's stdout
 *   GET  /shots/<relpath>        → serves a PNG out of e2e/screenshots/
 *
 * Fully dependency-light — uses Node's built-in http + fs and `npx playwright`.
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

const PORT = parseInt(process.env.REVIEW_PORT ?? '4244', 10)

// --- in-memory state for the latest run -----------------------------------
let runOutput = ''
let runRunning = false
const sseClients: http.ServerResponse[] = []

function broadcast(line: string) {
  runOutput += line
  const payload = `data: ${JSON.stringify({ line })}\n\n`
  for (const c of sseClients) { try { c.write(payload) } catch { /* drop */ } }
}

function runPlaywright(specRel: string | '') {
  if (runRunning) return false
  runRunning = true
  runOutput = ''
  broadcast(`$ npx playwright test ${specRel || '(all)'}\n`)
  const args = ['playwright', 'test']
  if (specRel) args.push(specRel)
  const child = spawn('npx', args, { cwd: WEB, env: { ...process.env, FORCE_COLOR: '0' } })
  child.stdout.on('data', (d: Buffer) => broadcast(d.toString()))
  child.stderr.on('data', (d: Buffer) => broadcast(d.toString()))
  child.on('close', (code) => {
    broadcast(`\n[exit ${code}]\n`)
    runRunning = false
  })
  return true
}

// --- file scanning --------------------------------------------------------
function listScreenshots(): { rel: string; size: number; mtime: number }[] {
  if (!fs.existsSync(SHOTS)) return []
  const out: { rel: string; size: number; mtime: number }[] = []
  function walk(dir: string) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, e.name)
      if (e.isDirectory()) walk(p)
      else if (/\.(png|jpe?g)$/i.test(e.name)) {
        const st = fs.statSync(p)
        out.push({ rel: path.relative(SHOTS, p), size: st.size, mtime: st.mtimeMs })
      }
    }
  }
  walk(SHOTS)
  return out.sort((a, b) => b.mtime - a.mtime)
}

function listSpecs(): string[] {
  if (!fs.existsSync(E2E)) return []
  return fs.readdirSync(E2E)
    .filter(n => n.endsWith('.spec.ts'))
    .map(n => path.join('e2e', n))
}

// --- HTML page ------------------------------------------------------------
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
  header .right { margin-left: auto; display: flex; gap: 8px; align-items: center; }
  select, button { background: #1a1a1c; color: #eee; border: 1px solid #333; border-radius: 6px; padding: 6px 10px; font: inherit; cursor: pointer; }
  select:hover, button:hover { background: #222226; }
  button.primary { background: #0066cc; border-color: #0066cc; }
  button.primary:hover { background: #0077ee; }
  button:disabled { opacity: 0.5; cursor: not-allowed; }
  main { padding: 16px; }
  .group { margin-bottom: 24px; }
  .group h2 { font-size: 12px; color: #888; text-transform: uppercase; letter-spacing: 0.06em; margin: 0 0 8px; font-weight: 600; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(360px, 1fr)); gap: 12px; }
  figure { margin: 0; background: #131316; border: 1px solid #262629; border-radius: 8px; overflow: hidden; }
  figure img { display: block; width: 100%; cursor: zoom-in; background: #000; }
  figcaption { padding: 6px 10px; font-size: 11px; color: #999; display: flex; justify-content: space-between; }
  pre.output { background: #0a0a0c; border: 1px solid #2a2a2a; border-radius: 6px; padding: 10px; max-height: 300px; overflow: auto; font: 11px/1.4 ui-monospace,monospace; white-space: pre-wrap; }
  .empty { color: #666; padding: 20px; text-align: center; }
  .badge { padding: 2px 6px; background: #2a2a2c; border-radius: 4px; font-size: 11px; }
  .badge.running { background: #0a4d0a; }
  a { color: #4aa3ff; }
  /* Lightbox */
  dialog { background: rgba(0,0,0,0.95); border: none; max-width: 100vw; max-height: 100vh; padding: 0; }
  dialog img { max-width: 100vw; max-height: 100vh; display: block; cursor: zoom-out; }
  dialog::backdrop { background: rgba(0,0,0,0.9); }
</style>
</head>
<body>
<header>
  <h1>Ask · review</h1>
  <span id="status" class="badge">idle</span>
  <div class="right">
    <select id="spec">
      <option value="">All specs</option>
    </select>
    <button id="run" class="primary">Run</button>
    <a href="http://localhost:5173/dev/markdown" target="_blank"><button>/dev/markdown ↗</button></a>
    <a href="http://localhost:5173/" target="_blank"><button>app ↗</button></a>
  </div>
</header>
<main>
  <pre id="output" class="output" hidden></pre>
  <div id="shots"></div>
</main>
<dialog id="lightbox"><img alt=""></dialog>
<script>
const specEl = document.getElementById('spec');
const runEl = document.getElementById('run');
const statusEl = document.getElementById('status');
const outputEl = document.getElementById('output');
const shotsEl = document.getElementById('shots');
const lightbox = document.getElementById('lightbox');
const lightboxImg = lightbox.querySelector('img');

lightboxImg.addEventListener('click', () => lightbox.close());
lightbox.addEventListener('click', (e) => { if (e.target === lightbox) lightbox.close(); });

async function loadSpecs() {
  const r = await fetch('/api/specs').then(r => r.json());
  for (const s of r) {
    const o = document.createElement('option');
    o.value = s; o.textContent = s.replace(/^e2e\\//, '');
    specEl.appendChild(o);
  }
}

function fmt(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024*1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1024 / 1024).toFixed(1) + ' MB';
}

function ago(ms) {
  const s = (Date.now() - ms) / 1000;
  if (s < 60) return Math.round(s) + 's ago';
  if (s < 3600) return Math.round(s/60) + 'm ago';
  return Math.round(s/3600) + 'h ago';
}

async function loadShots() {
  const r = await fetch('/api/screenshots').then(r => r.json());
  shotsEl.innerHTML = '';
  if (!r.length) { shotsEl.innerHTML = '<p class="empty">No screenshots yet — pick a spec and hit Run.</p>'; return; }
  // group by top directory
  const groups = new Map();
  for (const s of r) {
    const parts = s.rel.split('/');
    const g = parts.length > 1 ? parts[0] : '(root)';
    if (!groups.has(g)) groups.set(g, []);
    groups.get(g).push(s);
  }
  for (const [g, items] of groups) {
    const groupDiv = document.createElement('div');
    groupDiv.className = 'group';
    const h = document.createElement('h2'); h.textContent = g + ' — ' + items.length; groupDiv.appendChild(h);
    const grid = document.createElement('div'); grid.className = 'grid';
    for (const s of items) {
      const fig = document.createElement('figure');
      const img = document.createElement('img');
      img.src = '/shots/' + encodeURI(s.rel) + '?t=' + s.mtime;
      img.loading = 'lazy';
      img.alt = s.rel;
      img.addEventListener('click', () => { lightboxImg.src = img.src; lightbox.showModal(); });
      const cap = document.createElement('figcaption');
      cap.innerHTML = '<span>' + s.rel.split('/').pop() + '</span><span>' + fmt(s.size) + ' · ' + ago(s.mtime) + '</span>';
      fig.appendChild(img); fig.appendChild(cap);
      grid.appendChild(fig);
    }
    groupDiv.appendChild(grid);
    shotsEl.appendChild(groupDiv);
  }
}

runEl.addEventListener('click', async () => {
  outputEl.hidden = false;
  outputEl.textContent = '';
  statusEl.textContent = 'running…'; statusEl.className = 'badge running';
  runEl.disabled = true;
  await fetch('/api/run', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ spec: specEl.value }) });
});

const es = new EventSource('/api/output');
es.addEventListener('line', (e) => {
  const { line } = JSON.parse(e.data);
  outputEl.hidden = false;
  outputEl.textContent += line;
  outputEl.scrollTop = outputEl.scrollHeight;
});
es.addEventListener('done', () => {
  statusEl.textContent = 'idle'; statusEl.className = 'badge';
  runEl.disabled = false;
  loadShots();
});

loadSpecs();
loadShots();
setInterval(loadShots, 5000);
</script>
</body></html>`

// --- HTTP server ----------------------------------------------------------
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://localhost:${PORT}`)
  const p = url.pathname

  if (p === '/' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    res.end(HTML)
    return
  }

  if (p === '/api/specs' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(listSpecs()))
    return
  }

  if (p === '/api/screenshots' && req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify(listScreenshots()))
    return
  }

  if (p === '/api/run' && req.method === 'POST') {
    let body = ''
    req.on('data', d => body += d)
    req.on('end', () => {
      let spec = ''
      try { spec = (JSON.parse(body) as { spec?: string }).spec ?? '' } catch { /* */ }
      const ok = runPlaywright(spec)
      res.writeHead(ok ? 202 : 409, { 'Content-Type': 'application/json' })
      res.end(JSON.stringify({ ok }))
    })
    return
  }

  if (p === '/api/output' && req.method === 'GET') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    })
    res.write(': connected\n\n')
    if (runOutput) res.write(`event: line\ndata: ${JSON.stringify({ line: runOutput })}\n\n`)
    sseClients.push(res)
    const interval = setInterval(() => {
      if (!runRunning) {
        res.write('event: done\ndata: {}\n\n')
      }
    }, 1000)
    req.on('close', () => {
      clearInterval(interval)
      const i = sseClients.indexOf(res); if (i >= 0) sseClients.splice(i, 1)
    })
    return
  }

  if (p.startsWith('/shots/') && req.method === 'GET') {
    const rel = decodeURIComponent(p.replace('/shots/', ''))
    const full = path.join(SHOTS, rel)
    if (!full.startsWith(SHOTS) || !fs.existsSync(full)) { res.writeHead(404); res.end('not found'); return }
    res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'public, max-age=60' })
    fs.createReadStream(full).pipe(res)
    return
  }

  res.writeHead(404); res.end('not found')
})

server.listen(PORT, () => {
  console.log(`Ask · review dashboard → http://localhost:${PORT}`)
})
