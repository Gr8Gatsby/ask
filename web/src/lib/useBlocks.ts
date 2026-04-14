import { useState, useEffect, useCallback } from 'react'
import * as api from './api'
import type { Block } from './types'

export function useBlocks() {
  const [blocks, setBlocks] = useState<Block[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    api.getBlocks()
      .then(b => { setBlocks(b); setLoading(false) })
      .catch(e => { setError(String(e)); setLoading(false) })

    const unsub = api.subscribeToEvents((event) => {
      if (event.type === 'block_added' || event.type === 'block_updated') {
        setBlocks(prev => {
          const idx = prev.findIndex(b => b.blockID === event.block.blockID)
          if (idx >= 0) {
            const next = [...prev]
            next[idx] = event.block
            return next
          }
          return [...prev, event.block]
        })
      } else if (event.type === 'block_cleared') {
        setBlocks(prev => prev.filter(b => b.blockID !== event.blockID))
      }
    })

    return unsub
  }, [])

  const respond = useCallback(async (blockID: string, value: string) => {
    await api.respond(blockID, value)
  }, [])

  // Group tile-type blocks by scriptID
  const scriptGroups = blocks
    .filter(b => b.scriptType === 'tile')
    .reduce<Record<string, Block[]>>((acc, block) => {
      if (!acc[block.scriptID]) acc[block.scriptID] = []
      acc[block.scriptID].push(block)
      return acc
    }, {})

  // Blocks that need a response, sorted by urgency
  const urgencyOrder = { urgent: 0, warning: 1, info: 2 }
  const needsResponse = blocks
    .filter(b => b.requiresResponse === 1)
    .sort((a, b) => {
      const pa = tryParse<{ urgency?: string }>(a.payload)
      const pb = tryParse<{ urgency?: string }>(b.payload)
      const ua = urgencyOrder[(pa?.urgency ?? 'warning') as keyof typeof urgencyOrder] ?? 1
      const ub = urgencyOrder[(pb?.urgency ?? 'warning') as keyof typeof urgencyOrder] ?? 1
      return ua - ub
    })

  return { blocks, loading, error, respond, scriptGroups, needsResponse }
}

function tryParse<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}
