import http from 'http'
import type { IncomingMessage, ServerResponse } from 'http'
import { FIXTURE_BLOCKS } from './data/blocks.js'
import { FIXTURE_MACHINES } from './data/machines.js'
import { FIXTURE_TASKS, FIXTURE_TASK_MESSAGES } from './data/tasks.js'
import type { Block } from '../src/lib/types.js'

const PORT = 4242

let blocks: Block[] = [...FIXTURE_BLOCKS]
let sseClients: ServerResponse[] = []
let feedSeq = 100  // incrementing IDs for dynamically added feed items

function makeBlock(partial: Partial<Block> & Pick<Block, 'blockID' | 'scriptID' | 'scriptName' | 'blockType' | 'payload'>): Block {
  return {
    machineID: 'mac-dev-1',
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

// Simulate what a real script does after the user responds to a block
function simulateScriptResponse(blockID: string, value: string) {
  // ---- Brew Monitor ----
  if (blockID === 'brew-quick-reply') {
    const id = ++feedSeq
    if (value === 'Update All') {
      // Update tile to show updating then done
      upsertBlock(makeBlock({
        blockID: 'brew-tile',
        scriptID: 'brew-monitor',
        scriptName: 'Brew Monitor',
        blockType: 'tile',
        payload: JSON.stringify({ label: 'Updating…', status_color: 'blue' }),
      }))
      // Clear the alert block too
      const alertIdx = blocks.findIndex(b => b.blockID === 'brew-alert')
      if (alertIdx >= 0) { blocks.splice(alertIdx, 1); broadcast('block_cleared', { blockID: 'brew-alert' }) }
      // After a simulated delay, mark done and add feed entry
      setTimeout(() => {
        upsertBlock(makeBlock({
          blockID: 'brew-tile',
          scriptID: 'brew-monitor',
          scriptName: 'Brew Monitor',
          blockType: 'tile',
          payload: JSON.stringify({ label: 'Up to date', status_color: 'green' }),
        }))
        upsertBlock(makeBlock({
          blockID: `feed-brew-${id}`,
          scriptID: 'brew-monitor',
          scriptName: 'Brew Monitor',
          blockType: 'feed_item',
          scriptType: 'feed',
          payload: JSON.stringify({
            title: '3 packages updated',
            body: 'openssl 3.4.1, git 2.47.2, node 22.13.0',
            timestamp: new Date().toISOString(),
            color: 'green',
          }),
        }))
      }, 1500)
    } else {
      // Skip — just update tile back to idle and add feed entry
      upsertBlock(makeBlock({
        blockID: 'brew-tile',
        scriptID: 'brew-monitor',
        scriptName: 'Brew Monitor',
        blockType: 'tile',
        payload: JSON.stringify({ label: 'Updates skipped', status_color: 'orange' }),
      }))
      upsertBlock(makeBlock({
        blockID: `feed-brew-${id}`,
        scriptID: 'brew-monitor',
        scriptName: 'Brew Monitor',
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
  }

  // ---- Claude Code confirmation ----
  if (blockID === 'claudecode-confirmation-lint') {
    const id = ++feedSeq
    const label = value === 'Fix & Commit' ? 'Lint fixed & committed' : value === 'Skip Lint' ? 'Lint skipped' : 'Cancelled'
    const color = value === 'Fix & Commit' ? 'green' : value === 'Cancel' ? 'red' : 'orange'
    upsertBlock(makeBlock({
      blockID: `feed-claude-${id}`,
      scriptID: 'claude-3',
      scriptName: 'Claude Code',
      blockType: 'feed_item',
      scriptType: 'feed',
      payload: JSON.stringify({
        title: label,
        body: value === 'Fix & Commit' ? 'auth.ts — 3 lint errors auto-fixed and committed' : undefined,
        timestamp: new Date().toISOString(),
        color,
      }),
    }))
  }
}

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

const server = http.createServer(async (req, res) => {
  setCORS(res)

  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return }

  const url = new URL(req.url!, `http://localhost:${PORT}`)
  const path = url.pathname

  // GET /blocks
  if (req.method === 'GET' && path === '/blocks') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ blocks }))
    return
  }

  // GET /events  (SSE)
  if (req.method === 'GET' && path === '/events') {
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

  // POST /respond/:blockID
  const respondMatch = path.match(/^\/respond\/(.+)$/)
  if (req.method === 'POST' && respondMatch) {
    const blockID = respondMatch[1]
    const body = await readBody(req)
    const { value } = JSON.parse(body) as { value: string }
    console.log(`[MockAskMac] respond ${blockID} → "${value}"`)
    const prev = blocks.length
    blocks = blocks.filter(b => b.blockID !== blockID)
    if (blocks.length < prev) {
      broadcast('block_cleared', { blockID })
      simulateScriptResponse(blockID, value)
    }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ ok: true }))
    return
  }

  // GET /machines
  if (req.method === 'GET' && path === '/machines') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ machines: FIXTURE_MACHINES }))
    return
  }

  // GET /tasks
  if (req.method === 'GET' && path === '/tasks') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({ tasks: FIXTURE_TASKS }))
    return
  }

  // GET /tasks/:taskID/messages
  const taskMsgMatch = path.match(/^\/tasks\/([^/]+)\/messages$/)
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
})
