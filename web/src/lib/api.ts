import type { Block, Machine, AskTask, TaskArtifact, TaskMessage, SSEEvent } from './types'
import { logDebug } from './debugLog'

const BASE = '/api'

export async function getBlocks(): Promise<Block[]> {
  const res = await fetch(`${BASE}/blocks`)
  const data = await res.json() as { blocks: Block[] }
  return data.blocks
}

export async function respond(blockID: string, value: string): Promise<void> {
  const truncated = value.length > 80 ? value.slice(0, 80) + '…' : value
  logDebug({ dir: '→', category: 'RESPOND', label: `respond ${blockID}`, detail: truncated })
  try {
    const res = await fetch(`${BASE}/respond/${blockID}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ value }),
    })
    if (res.ok) {
      logDebug({ dir: '←', category: 'RESPOND', label: `respond ${blockID} → ${res.status} OK` })
    } else {
      logDebug({ dir: '←', category: 'RESPOND', label: `respond ${blockID} → ${res.status} error`, error: true })
    }
  } catch (e) {
    logDebug({ dir: '←', category: 'RESPOND', label: `respond ${blockID} → fetch error`, detail: String(e), error: true })
    throw e
  }
}

export async function getMachines(): Promise<Machine[]> {
  const res = await fetch(`${BASE}/machines`)
  const data = await res.json() as { machines: Machine[] }
  return data.machines
}

export async function getTasks(): Promise<AskTask[]> {
  const res = await fetch(`${BASE}/tasks`)
  const data = await res.json() as { tasks: AskTask[] }
  return data.tasks
}

export async function getTaskMessages(taskID: string): Promise<TaskMessage[]> {
  const res = await fetch(`${BASE}/tasks/${taskID}/messages`)
  if (!res.ok) return []
  const data = await res.json() as { messages?: TaskMessage[] }
  // Sort by timestamp first; sequenceNumber as tiebreaker. The backend's
  // sequenceNumber counter can reset across AskMac TaskRegistry restarts,
  // producing duplicates that group out-of-time-order messages together.
  // Timestamp is monotonic per-write so it gives a reliable chat order.
  return (data.messages ?? []).slice().sort((a, b) => {
    const t = (a.timestamp ?? '').localeCompare(b.timestamp ?? '')
    if (t !== 0) return t
    return (a.sequenceNumber ?? 0) - (b.sequenceNumber ?? 0)
  })
}

export async function getTaskArtifacts(taskID: string): Promise<TaskArtifact[]> {
  const res = await fetch(`${BASE}/tasks/${taskID}/artifacts`)
  if (!res.ok) return []
  const data = await res.json() as { artifacts?: TaskArtifact[] }
  return data.artifacts ?? []
}

export async function getArtifactContent(artifactID: string): Promise<string> {
  const res = await fetch(`${BASE}/artifacts/${artifactID}/content`)
  return res.text()
}

export function subscribeToEvents(onEvent: (event: SSEEvent) => void): () => void {
  const source = new EventSource(`${BASE}/events`)

  source.addEventListener('open', () => {
    logDebug({ dir: '←', category: 'CONN', label: 'SSE connected' })
  })

  source.addEventListener('error', () => {
    logDebug({ dir: '←', category: 'CONN', label: 'SSE error / reconnecting', error: true })
  })

  source.addEventListener('block_added', (e) => {
    const block = JSON.parse((e as MessageEvent).data) as Block
    logDebug({
      dir: '←', category: 'SSE',
      label: `block_added ${block.blockID}`,
      detail: `${block.scriptID} · ${block.blockType}`,
    })
    onEvent({ type: 'block_added', block })
  })

  source.addEventListener('block_updated', (e) => {
    const block = JSON.parse((e as MessageEvent).data) as Block
    logDebug({
      dir: '←', category: 'SSE',
      label: `block_updated ${block.blockID}`,
      detail: `${block.scriptID} · ${block.blockType}`,
    })
    onEvent({ type: 'block_updated', block })
  })

  source.addEventListener('block_cleared', (e) => {
    const { blockID } = JSON.parse((e as MessageEvent).data) as { blockID: string }
    logDebug({ dir: '←', category: 'SSE', label: `block_cleared ${blockID}` })
    onEvent({ type: 'block_cleared', blockID })
  })

  return () => source.close()
}

export function subscribeToDebugEvents(onEvent: (entry: { type: string; data: unknown }) => void): () => void {
  const source = new EventSource(`${BASE}/debug/events`)
  source.addEventListener('debug', (e) => {
    try {
      onEvent(JSON.parse((e as MessageEvent).data) as { type: string; data: unknown })
    } catch { /* ignore malformed */ }
  })
  return () => source.close()
}
