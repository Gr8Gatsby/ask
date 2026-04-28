export interface DebugEntry {
  id: number
  ts: number
  dir: '←' | '→' | '↕'
  category: 'SSE' | 'RESPOND' | 'SERVER' | 'CONN'
  label: string
  detail?: string
  error?: boolean
}

const MAX = 300
let seq = 0
let entries: DebugEntry[] = []
const listeners = new Set<(entries: DebugEntry[]) => void>()

function notify() {
  const copy = [...entries]
  for (const fn of listeners) fn(copy)
}

export function logDebug(entry: Omit<DebugEntry, 'id' | 'ts'>) {
  entries = [{ id: seq++, ts: Date.now(), ...entry }, ...entries].slice(0, MAX)
  notify()
}

export function subscribeDebug(fn: (entries: DebugEntry[]) => void): () => void {
  listeners.add(fn)
  fn([...entries])
  return () => { listeners.delete(fn) }
}

export function clearDebug() {
  entries = []
  seq = 0
  notify()
}
