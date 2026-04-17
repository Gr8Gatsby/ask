import type { Block, Machine, AskTask, TaskArtifact, TaskMessage, SSEEvent } from './types'

const BASE = '/api'

export async function getBlocks(): Promise<Block[]> {
  const res = await fetch(`${BASE}/blocks`)
  const data = await res.json() as { blocks: Block[] }
  return data.blocks
}

export async function respond(blockID: string, value: string): Promise<void> {
  await fetch(`${BASE}/respond/${blockID}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ value }),
  })
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
  return data.messages ?? []
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

  source.addEventListener('block_added', (e) => {
    onEvent({ type: 'block_added', block: JSON.parse((e as MessageEvent).data) as Block })
  })
  source.addEventListener('block_updated', (e) => {
    onEvent({ type: 'block_updated', block: JSON.parse((e as MessageEvent).data) as Block })
  })
  source.addEventListener('block_cleared', (e) => {
    const { blockID } = JSON.parse((e as MessageEvent).data) as { blockID: string }
    onEvent({ type: 'block_cleared', blockID })
  })

  return () => source.close()
}
