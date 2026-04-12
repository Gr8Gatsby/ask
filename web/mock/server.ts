import http from 'http'
import type { IncomingMessage, ServerResponse } from 'http'
import { FIXTURE_BLOCKS, CLAUDE3_NAME, CLAUDE3_ICON, BREW_NAME, BREW_ICON } from './data/blocks.js'
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

// Simulate what a real script does after the user responds to a block.
// Returns true if the caller should also clear+broadcast the block, false if
// this function handled the block update itself (agent_session stays alive).
function simulateScriptResponse(blockID: string, value: string): boolean {
  // ---- Brew Monitor ----
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
      // Clear the alert block too
      const alertIdx = blocks.findIndex(b => b.blockID === 'brew-alert')
      if (alertIdx >= 0) { blocks.splice(alertIdx, 1); broadcast('block_cleared', { blockID: 'brew-alert' }) }
      // Clear the countdown block
      const cdIdx = blocks.findIndex(b => b.blockID === 'brew-countdown')
      if (cdIdx >= 0) { blocks.splice(cdIdx, 1); broadcast('block_cleared', { blockID: 'brew-countdown' }) }
      // After a simulated delay, mark done and add feed entry
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
      // Skip — update tile and add feed entry
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
    return true  // clear the quick_reply block
  }

  // ---- Claude Code bash permission block ----
  // Clearing this block should also update the linked session block.
  if (blockID === 'claudecode-bash-permission') {
    const sessionIdx = blocks.findIndex(b => b.blockID === 'claudecode-session-a3f91c2b')
    if (sessionIdx >= 0) {
      const p = JSON.parse(blocks[sessionIdx].payload)
      delete p.pending_confirmation
      if (value === 'Allow') {
        p.is_working = true
        p.current_tool = 'Bash'
        p.current_preview = 'rsync --delete ask/scripts/ ~/.ask/scripts/claude-3/'
      } else {
        p.is_working = false
        p.last_message = 'Permission denied. The command was not run.'
      }
      blocks[sessionIdx] = { ...blocks[sessionIdx], payload: JSON.stringify(p) }
      broadcast('block_updated', blocks[sessionIdx])
    }
    return true  // clear the confirmation block
  }

  // ---- Claude Code session actions ----
  if (blockID === 'claudecode-session-a3f91c2b') {
    if (value === '__close_session__') {
      upsertBlock(makeBlock({
        blockID: `event-stopped-${++feedSeq}`,
        scriptID: 'claude-3',
        scriptName: CLAUDE3_NAME,
        scriptIconSVG: CLAUDE3_ICON,
        blockType: 'session_event',
        scriptType: 'tile',
        payload: JSON.stringify({ event: 'stopped', project: 'code/ask [a3f9]', cwd: '/Users/kevin/Documents/code/ask' }),
      }))
      upsertBlock(makeBlock({
        blockID: 'claudecode-tile',
        scriptID: 'claude-3',
        scriptName: CLAUDE3_NAME,
        scriptIconSVG: CLAUDE3_ICON,
        blockType: 'tile',
        payload: JSON.stringify({ label: 'Idle', status_color: 'green' }),
      }))
      return true  // clear the session block on stop
    } else if (value === '__permissions__') {
      // Toggle permission mode — update in-place
      const idx = blocks.findIndex(b => b.blockID === blockID)
      if (idx >= 0) {
        const p = JSON.parse(blocks[idx].payload)
        p.permission_mode = p.permission_mode === 'supervised' ? 'full-auto' : 'supervised'
        blocks[idx] = { ...blocks[idx], payload: JSON.stringify(p) }
        broadcast('block_updated', blocks[idx])
      }
      return false  // keep the session block alive
    } else {
      // Pending confirmation response — update in-place, keep session alive
      const idx = blocks.findIndex(b => b.blockID === blockID)
      if (idx >= 0) {
        const p = JSON.parse(blocks[idx].payload)
        delete p.pending_confirmation
        p.is_working = true
        p.current_tool = 'Bash'
        p.current_preview = value === 'Fix & Commit' ? 'npm run lint --fix && git commit' : 'git commit'
        blocks[idx] = { ...blocks[idx], payload: JSON.stringify(p) }
        broadcast('block_updated', blocks[idx])
      }
      // Clear the linked bash-permission block so the script fully exits "Needs Response"
      const bashIdx = blocks.findIndex(b => b.blockID === 'claudecode-bash-permission')
      if (bashIdx >= 0) {
        blocks.splice(bashIdx, 1)
        broadcast('block_cleared', { blockID: 'claudecode-bash-permission' })
      }
      return false  // keep the session block alive
    }
  }

  return true  // default: caller should clear
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
    const shouldClear = simulateScriptResponse(blockID, value)
    if (shouldClear) {
      const prev = blocks.length
      blocks = blocks.filter(b => b.blockID !== blockID)
      if (blocks.length < prev) broadcast('block_cleared', { blockID })
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
