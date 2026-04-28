import http from 'http'
import net from 'net'
import fs from 'fs'
import path from 'path'
import type { IncomingMessage, ServerResponse } from 'http'
import { BREW_NAME, BREW_ICON } from './data/blocks.js'
import { FIXTURE_MACHINES } from './data/machines.js'
import { FIXTURE_TASKS, FIXTURE_TASK_MESSAGES, FIXTURE_ARTIFACTS, FIXTURE_ARTIFACT_CONTENT } from './data/tasks.js'
import type { Block } from '../src/lib/types.js'

const PORT = parseInt(process.env.PORT ?? '4243', 10)
const HOME = process.env.HOME!

// AskMac writes this file whenever activeBlocks changes — it's the ground truth
// for what would be in CloudKit, so MockAskMac reads it directly.
const BLOCKS_SNAPSHOT_PATH = path.join(HOME, '.ask/blocks.json')

// Socket paths for sending ui_respond to daemons
const SOCKETS: Record<string, string> = {
  'claude-3':  path.join(HOME, '.ask/sockets/claude-3.sock'),
  'codex-2':   path.join(HOME, '.ask/sockets/codex-2.sock'),
  'codex-3':   path.join(HOME, '.ask/sockets/codex-3.sock'),
}

// ── Block snapshot reader ─────────────────────────────────────────────────────

function readSnapshotBlocks(): Block[] {
  try {
    const raw = JSON.parse(fs.readFileSync(BLOCKS_SNAPSHOT_PATH, 'utf-8')) as { blocks: Block[] }
    return raw.blocks ?? []
  } catch {
    return []
  }
}

// ── Block state ───────────────────────────────────────────────────────────────

let blocks: Block[] = readSnapshotBlocks()
let sseClients: ServerResponse[] = []
let debugClients: ServerResponse[] = []
let feedSeq = 100

function rebuildBlocks() {
  const newBlocks = readSnapshotBlocks()

  // Diff and broadcast changes
  for (const nb of newBlocks) {
    const old = blocks.find(b => b.blockID === nb.blockID)
    if (!old) {
      broadcast('block_added', nb)
    } else if (old.payload !== nb.payload || old.requiresResponse !== nb.requiresResponse) {
      broadcast('block_updated', nb)
    }
  }
  const newIDs = new Set(newBlocks.map(b => b.blockID))
  for (const ob of blocks) {
    if (!newIDs.has(ob.blockID)) broadcast('block_cleared', { blockID: ob.blockID })
  }

  blocks = newBlocks
  console.log(`[MockAskMac] snapshot refreshed — ${blocks.length} block(s)`)
  broadcastDebug('snapshot_reload', { blockCount: String(blocks.length) })
}

// Watch the snapshot file for live AskMac updates
if (fs.existsSync(BLOCKS_SNAPSHOT_PATH)) {
  fs.watchFile(BLOCKS_SNAPSHOT_PATH, { interval: 300 }, () => rebuildBlocks())
} else {
  // File doesn't exist yet — poll until AskMac creates it
  const interval = setInterval(() => {
    if (fs.existsSync(BLOCKS_SNAPSHOT_PATH)) {
      clearInterval(interval)
      fs.watchFile(BLOCKS_SNAPSHOT_PATH, { interval: 300 }, () => rebuildBlocks())
      rebuildBlocks()
      console.log(`[MockAskMac] blocks.json appeared, watching for updates`)
    }
  }, 2000)
}

// ── Block snapshot writer ─────────────────────────────────────────────────────

function removeBlockFromSnapshot(blockID: string) {
  try {
    const raw = JSON.parse(fs.readFileSync(BLOCKS_SNAPSHOT_PATH, 'utf-8')) as { blocks: Block[] }
    const filtered = (raw.blocks ?? []).filter(b => b.blockID !== blockID)
    if (filtered.length !== (raw.blocks ?? []).length) {
      fs.writeFileSync(BLOCKS_SNAPSHOT_PATH, JSON.stringify({ blocks: filtered }, null, 2))
      console.log(`[MockAskMac] removed block ${blockID} from snapshot`)
    }
  } catch {
    // snapshot may not exist or be malformed — ignore
  }
}

function clearBlock(blockID: string) {
  const prev = blocks.length
  blocks = blocks.filter(b => b.blockID !== blockID)
  if (blocks.length < prev) {
    broadcast('block_cleared', { blockID })
    removeBlockFromSnapshot(blockID)
  }
}

// ── Unix socket sender ────────────────────────────────────────────────────────

function sendToSocket(socketPath: string, message: object): Promise<void> {
  return new Promise((resolve) => {
    const client = net.createConnection(socketPath)
    let done = false
    const finish = () => { if (!done) { done = true; resolve() } }

    client.on('connect', () => {
      client.write(JSON.stringify(message))
      client.end()
    })
    client.on('end', finish)
    client.on('error', (err) => {
      console.error(`[MockAskMac] socket error (${socketPath}): ${err.message}`)
      finish()
    })
    setTimeout(finish, 3000)
  })
}

async function respondDaemon(scriptID: string, sessionID: string, value: string): Promise<void> {
  const socketPath = SOCKETS[scriptID]
  if (!socketPath) {
    console.warn(`[MockAskMac] no socket path for script ${scriptID}`)
    broadcastDebug('socket_error', { scriptID, sessionID, error: 'no socket path configured' })
    return
  }
  console.log(`[MockAskMac] ui_respond scriptID=${scriptID} session=${sessionID} value="${value}"`)
  broadcastDebug('socket_sent', { scriptID, sessionID, value })
  try {
    await sendToSocket(socketPath, { type: 'ui_respond', session_id: sessionID, value })
  } catch (e) {
    broadcastDebug('socket_error', { scriptID, sessionID, error: String(e) })
  }
}

// ── Brew fixture simulation (kept for brew-quick-reply testing) ───────────────

function makeBlock(partial: Partial<Block> & Pick<Block, 'blockID' | 'scriptID' | 'scriptName' | 'blockType' | 'payload'>): Block {
  return {
    machineID: 'mac-live',
    createdAt: new Date().toISOString(),
    requiresResponse: 0,
    showsInInbox: 0,
    scriptType: 'tile',
    ...partial,
  }
}

function upsertBlock(b: Block) {
  const idx = blocks.findIndex(x => x.blockID === b.blockID)
  if (idx >= 0) {
    blocks[idx] = b
    broadcast('block_updated', b)
  } else {
    blocks.push(b)
    broadcast('block_added', b)
  }
}

function simulateBrewResponse(blockID: string, value: string): boolean {
  if (blockID === 'brew-quick-reply') {
    const id = ++feedSeq
    if (value === 'Update All') {
      upsertBlock(makeBlock({
        blockID: 'brew-tile',
        scriptID: 'brew-monitor',
        scriptName: BREW_NAME,
        scriptIconSVG: BREW_ICON,
        blockType: 'tile',
        payload: JSON.stringify({ label: 'Updating…', status_color: 'blue' }),
      }))
      const alertIdx = blocks.findIndex(b => b.blockID === 'brew-alert')
      if (alertIdx >= 0) { blocks.splice(alertIdx, 1); broadcast('block_cleared', { blockID: 'brew-alert' }) }
      const cdIdx = blocks.findIndex(b => b.blockID === 'brew-countdown')
      if (cdIdx >= 0) { blocks.splice(cdIdx, 1); broadcast('block_cleared', { blockID: 'brew-countdown' }) }
      setTimeout(() => {
        upsertBlock(makeBlock({
          blockID: 'brew-tile',
          scriptID: 'brew-monitor',
          scriptName: BREW_NAME,
          scriptIconSVG: BREW_ICON,
          blockType: 'tile',
          payload: JSON.stringify({ label: 'Up to date', status_color: 'green' }),
        }))
        upsertBlock(makeBlock({
          blockID: `feed-brew-${id}`,
          scriptID: 'brew-monitor',
          scriptName: BREW_NAME,
          scriptIconSVG: BREW_ICON,
          blockType: 'feed_item',
          scriptType: 'feed',
          payload: JSON.stringify({
            title: '3 packages updated',
            body: 'openssl 3.4.1, git 2.47.2, node 22.13.0',
            timestamp: new Date().toISOString(),
            color: 'green',
          }),
        }))
      }, 2000)
    } else {
      upsertBlock(makeBlock({
        blockID: 'brew-tile',
        scriptID: 'brew-monitor',
        scriptName: BREW_NAME,
        scriptIconSVG: BREW_ICON,
        blockType: 'tile',
        payload: JSON.stringify({ label: 'Updates skipped', status_color: 'orange' }),
      }))
      upsertBlock(makeBlock({
        blockID: `feed-brew-${id}`,
        scriptID: 'brew-monitor',
        scriptName: BREW_NAME,
        scriptIconSVG: BREW_ICON,
        blockType: 'feed_item',
        scriptType: 'feed',
        payload: JSON.stringify({
          title: 'Updates skipped',
          body: 'openssl, git, node — skipped by user',
          timestamp: new Date().toISOString(),
          color: 'orange',
        }),
      }))
    }
    return true
  }
  return true
}

// ── SSE helpers ───────────────────────────────────────────────────────────────

function broadcast(eventName: string, data: unknown) {
  const payload = `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`
  sseClients = sseClients.filter(client => {
    try { client.write(payload); return true } catch { return false }
  })
}

function broadcastDebug(type: string, data: Record<string, string>) {
  const payload = `event: debug\ndata: ${JSON.stringify({ type, data })}\n\n`
  debugClients = debugClients.filter(client => {
    try { client.write(payload); return true } catch { return false }
  })
}

function setCORS(res: ServerResponse) {
  res.setHeader('Access-Control-Allow-Origin', '*')
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type')
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise(resolve => {
    let body = ''
    req.on('data', chunk => { body += chunk })
    req.on('end', () => resolve(body))
  })
}

// ── HTTP server ───────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  setCORS(res)

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return }

  const url = new URL(req.url!, `http://localhost:${PORT}`)
  const p = url.pathname

  if (req.method === 'GET' && p === '/blocks') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ blocks }))
    return
  }

  if (req.method === 'GET' && p === '/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    })
    res.write(': connected\n\n')
    sseClients.push(res)
    req.on('close', () => { sseClients = sseClients.filter(c => c !== res) })
    return
  }

  if (req.method === 'GET' && p === '/debug/events') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
    })
    res.write(': debug connected\n\n')
    debugClients.push(res)
    req.on('close', () => { debugClients = debugClients.filter(c => c !== res) })
    return
  }

  const respondMatch = p.match(/^\/respond\/(.+)$/)
  if (req.method === 'POST' && respondMatch) {
    const blockID = respondMatch[1]
    const body = await readBody(req)
    const { value } = JSON.parse(body) as { value: string }
    console.log(`[MockAskMac] respond ${blockID} → "${value}"`)

    // Find the block to determine its scriptID, then route to the right daemon
    const block = blocks.find(b => b.blockID === blockID)
    const scriptID = block?.scriptID ?? ''
    broadcastDebug('respond_received', { blockID, value, scriptID })

    if (scriptID in SOCKETS) {
      // Forward to live daemon, then clear if it was a stop request
      try {
        const payload = JSON.parse(block?.payload ?? '{}') as { session_id?: string }
        const sessionID = payload.session_id ?? blockID
        await respondDaemon(scriptID, sessionID, value)
      } catch {
        await respondDaemon(scriptID, blockID, value)
      }
      // Always clear session block on stop — daemon may be dead
      if (value === '__close_session__') clearBlock(blockID)
    } else if (blockID.startsWith('brew-')) {
      const shouldClear = simulateBrewResponse(blockID, value)
      if (shouldClear) clearBlock(blockID)
    } else {
      clearBlock(blockID)
    }

    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true }))
    return
  }

  if (req.method === 'GET' && p === '/machines') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ machines: FIXTURE_MACHINES }))
    return
  }

  if (req.method === 'GET' && p === '/tasks') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ tasks: FIXTURE_TASKS }))
    return
  }

  const taskMsgMatch = p.match(/^\/tasks\/([^/]+)\/messages$/)
  if (req.method === 'GET' && taskMsgMatch) {
    const taskID = taskMsgMatch[1]
    const messages = FIXTURE_TASK_MESSAGES[taskID] ?? []
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ messages }))
    return
  }

  const taskArtifactsMatch = p.match(/^\/tasks\/([^/]+)\/artifacts$/)
  if (req.method === 'GET' && taskArtifactsMatch) {
    const taskID = taskArtifactsMatch[1]
    const artifacts = FIXTURE_ARTIFACTS[taskID] ?? []
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ artifacts }))
    return
  }

  const artifactContentMatch = p.match(/^\/artifacts\/([^/]+)\/content$/)
  if (req.method === 'GET' && artifactContentMatch) {
    const artifactID = artifactContentMatch[1]
    const content = FIXTURE_ARTIFACT_CONTENT[artifactID]
    if (content) {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end(content)
    } else {
      // Generate placeholder content for artifacts without fixture content
      const allArtifacts = Object.values(FIXTURE_ARTIFACTS).flat()
      const artifact = allArtifacts.find(a => a.artifactID === artifactID)
      const placeholder = artifact
        ? `// ${artifact.filename}\n// Generated by ${artifact.description ?? 'Claude Code'}\n// Size: ${artifact.sizeBytes} bytes\n\n// File content not available in mock server.`
        : '// Content not available'
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end(placeholder)
    }
    return
  }

  res.writeHead(404)
  res.end('Not found')
})

server.listen(PORT, () => {
  console.log(`MockAskMac  http://localhost:${PORT}`)
  console.log(`  Block snapshot: ${BLOCKS_SNAPSHOT_PATH}`)
  rebuildBlocks()
})
