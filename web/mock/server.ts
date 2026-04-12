import http from 'http'
import net from 'net'
import fs from 'fs'
import path from 'path'
import type { IncomingMessage, ServerResponse } from 'http'
import { FIXTURE_BREW_BLOCKS, CLAUDE3_NAME, CLAUDE3_ICON, BREW_NAME, BREW_ICON } from './data/blocks.js'
import { FIXTURE_MACHINES } from './data/machines.js'
import { FIXTURE_TASKS, FIXTURE_TASK_MESSAGES } from './data/tasks.js'
import type { Block } from '../src/lib/types.js'

const PORT = 4242
const HOME = process.env.HOME!
const SESSIONS_PATH = path.join(HOME, '.ask/claude3-sessions.json')
const SOCKET_PATH = path.join(HOME, '.ask/sockets/claude-3.sock')
const SESSION_TTL = 86400  // 24 hours

// ---- Live session state from ~/.ask/claude3-sessions.json ----

interface RawSession {
  session_id: string
  task_id?: string
  project: string
  cwd: string
  state: string          // 'idle' | 'starting' | 'running_tool' | 'working' | 'stopping' | 'stopped'
  current_tool: string
  preview: string
  last_message: string
  last_seen: number
  is_transient: boolean
  permission_mode: string
  pending_permission: {
    request_id: string
    tool: string
    preview: string
    options: string[]
  } | null
}

function readSessions(): Record<string, RawSession> {
  try {
    return JSON.parse(fs.readFileSync(SESSIONS_PATH, 'utf-8')) as Record<string, RawSession>
  } catch {
    return {}
  }
}

function sessionToBlock(sid: string, s: RawSession): Block | null {
  const now = Date.now() / 1000
  if (s.state === 'stopped') return null
  if (now - s.last_seen > SESSION_TTL) return null
  if (s.is_transient) return null

  const isWorking = s.state === 'running_tool' || s.state === 'working' || s.state === 'starting'
  const pending = s.pending_permission
    ? {
        title: `Allow ${s.pending_permission.tool}?`,
        body: s.pending_permission.preview || undefined,
        options: s.pending_permission.options,
      }
    : undefined

  return {
    blockID: `claude3-live-${sid}`,
    machineID: 'mac-live',
    scriptID: 'claude-3',
    scriptName: CLAUDE3_NAME,
    scriptIconSVG: CLAUDE3_ICON,
    blockType: 'agent_session',
    scriptType: 'tile',
    createdAt: new Date(s.last_seen * 1000).toISOString(),
    requiresResponse: pending ? 1 : 0,
    showsInInbox: 0,
    payload: JSON.stringify({
      session_id: sid,
      task_id: s.task_id ?? sid,
      project: s.project,
      cwd: s.cwd,
      last_message: s.last_message || undefined,
      is_working: isWorking,
      current_tool: isWorking && s.current_tool ? s.current_tool : undefined,
      current_preview: isWorking && s.preview ? s.preview : undefined,
      agent_name: 'Claude Code',
      brand_color: '#74AA9C',
      placeholder: 'Reply to Claude…',
      permission_mode: s.permission_mode ?? 'supervised',
      pending_confirmation: pending,
    }),
  }
}

function buildClaude3Blocks(): Block[] {
  const sessions = readSessions()
  const sessionBlocks: Block[] = []

  for (const [sid, s] of Object.entries(sessions)) {
    const b = sessionToBlock(sid, s)
    if (b) sessionBlocks.push(b)
  }

  // Derive tile label from live session state
  const working = sessionBlocks.filter(b => {
    try { return (JSON.parse(b.payload) as { is_working?: boolean }).is_working } catch { return false }
  })
  const tileLabel = sessionBlocks.length === 0
    ? 'Idle'
    : working.length > 0
    ? `${working.length} session${working.length > 1 ? 's' : ''} working`
    : `${sessionBlocks.length} session${sessionBlocks.length > 1 ? 's' : ''}`

  const tile: Block = {
    blockID: 'claude3-tile',
    machineID: 'mac-live',
    scriptID: 'claude-3',
    scriptName: CLAUDE3_NAME,
    scriptIconSVG: CLAUDE3_ICON,
    blockType: 'tile',
    scriptType: 'tile',
    createdAt: new Date().toISOString(),
    requiresResponse: 0,
    showsInInbox: 0,
    payload: JSON.stringify({
      label: tileLabel,
      status_color: working.length > 0 ? 'blue' : sessionBlocks.length > 0 ? 'green' : 'green',
    }),
  }

  return [tile, ...sessionBlocks]
}

// ---- Block state (live claude-3 + fixture brew) ----

let blocks: Block[] = [...buildClaude3Blocks(), ...FIXTURE_BREW_BLOCKS]
let sseClients: ServerResponse[] = []
let feedSeq = 100

function rebuildClaude3Blocks() {
  const newLive = buildClaude3Blocks()
  const brew = blocks.filter(b => b.scriptID !== 'claude-3')

  // Diff: broadcast updates for changed blocks
  for (const nb of newLive) {
    const old = blocks.find(b => b.blockID === nb.blockID)
    if (!old) {
      broadcast('block_added', nb)
    } else if (old.payload !== nb.payload) {
      broadcast('block_updated', nb)
    }
  }
  // Broadcast removals
  const newIDs = new Set(newLive.map(b => b.blockID))
  for (const ob of blocks.filter(b => b.scriptID === 'claude-3')) {
    if (!newIDs.has(ob.blockID)) broadcast('block_cleared', { blockID: ob.blockID })
  }

  blocks = [...newLive, ...brew]
  console.log(`[MockAskMac] sessions refreshed — ${newLive.length - 1} session(s)`)
}

// Watch ~/.ask/claude3-sessions.json for live updates
fs.watchFile(SESSIONS_PATH, { interval: 500 }, () => rebuildClaude3Blocks())

// ---- Respond via daemon Unix socket (for claude-3 blocks) ----

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
      console.error(`[MockAskMac] socket error: ${err.message}`)
      finish()
    })
    setTimeout(finish, 3000)
  })
}

async function respondClaude3(sessionID: string, value: string): Promise<void> {
  console.log(`[MockAskMac] ui_respond session=${sessionID} value="${value}"`)
  await sendToSocket(SOCKET_PATH, { type: 'ui_respond', session_id: sessionID, value })
  // Daemon updates sessions file; watcher will pick it up within 500ms
}

// ---- Brew fixture simulation (unchanged) ----

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

// Returns true if the caller should clear the block, false if handled in-place
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

// ---- SSE helpers ----

function broadcast(eventName: string, data: unknown) {
  const payload = `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`
  sseClients = sseClients.filter(client => {
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

// ---- HTTP server ----

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

  const respondMatch = p.match(/^\/respond\/(.+)$/)
  if (req.method === 'POST' && respondMatch) {
    const blockID = respondMatch[1]
    const body = await readBody(req)
    const { value } = JSON.parse(body) as { value: string }
    console.log(`[MockAskMac] respond ${blockID} → "${value}"`)

    // Route to live daemon or brew fixture simulation
    const liveMatch = blockID.match(/^claude3-live-(.+)$/)
    if (liveMatch) {
      await respondClaude3(liveMatch[1], value)
    } else {
      const shouldClear = simulateBrewResponse(blockID, value)
      if (shouldClear) {
        const prev = blocks.length
        blocks = blocks.filter(b => b.blockID !== blockID)
        if (blocks.length < prev) broadcast('block_cleared', { blockID })
      }
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

  res.writeHead(404)
  res.end('Not found')
})

server.listen(PORT, () => {
  console.log(`MockAskMac  http://localhost:${PORT}`)
  console.log(`  Sessions: ${SESSIONS_PATH}`)
  console.log(`  Socket:   ${SOCKET_PATH}`)
  rebuildClaude3Blocks()
})
