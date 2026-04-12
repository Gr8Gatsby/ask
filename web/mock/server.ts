import http from 'http'
import type { IncomingMessage, ServerResponse } from 'http'
import { FIXTURE_BLOCKS } from './data/blocks.js'
import { FIXTURE_MACHINES } from './data/machines.js'
import { FIXTURE_TASKS, FIXTURE_TASK_MESSAGES } from './data/tasks.js'
import type { Block } from '../src/lib/types.js'

const PORT = 4242

let blocks: Block[] = [...FIXTURE_BLOCKS]
let sseClients: ServerResponse[] = []

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
    if (blocks.length < prev) broadcast('block_cleared', { blockID })
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
