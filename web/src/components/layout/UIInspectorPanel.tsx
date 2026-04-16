import { useLocation } from 'react-router-dom'
import { useState, useEffect } from 'react'
import { useBlocks } from '../../lib/useBlocks'
import { useRedlines } from '../../lib/RedlinesContext'
import type { Block } from '../../lib/types'

type ScreenInfo = {
  name: string
  params: Record<string, string>
  filterBlocks: (blocks: Block[]) => Block[]
}

// Map pathname patterns to friendly screen names and block filters that mirror each screen's usage
function getScreenInfo(pathname: string): ScreenInfo {
  const sessionMatch = pathname.match(/^\/script\/([^/]+)\/session\/([^/]+)/)
  if (sessionMatch) {
    const scriptID = sessionMatch[1]
    const sessionID = sessionMatch[2]
    return {
      name: 'Session Chat',
      params: { scriptID, sessionID },
      // Only the agent_session block for this specific session drives this screen
      filterBlocks: (blocks) => blocks.filter(b =>
        b.scriptID === scriptID &&
        b.blockType === 'agent_session' &&
        (() => { try { return (JSON.parse(b.payload) as { session_id?: string }).session_id === sessionID } catch { return false } })()
      ),
    }
  }
  const scriptMatch = pathname.match(/^\/script\/([^/]+)/)
  if (scriptMatch) {
    const scriptID = scriptMatch[1]
    return {
      name: 'Script Detail',
      params: { scriptID },
      filterBlocks: (blocks) => blocks.filter(b => b.scriptID === scriptID),
    }
  }
  const taskMatch = pathname.match(/^\/tasks\/([^/]+)/)
  if (taskMatch) {
    return {
      name: 'Task Thread',
      params: { taskID: taskMatch[1] },
      filterBlocks: () => [],
    }
  }
  if (pathname.startsWith('/tasks')) {
    return {
      name: 'Task Feed',
      params: {},
      filterBlocks: (blocks) => blocks.filter(b => b.blockType === 'agent_session'),
    }
  }
  if (pathname.startsWith('/settings')) {
    return { name: 'Settings', params: {}, filterBlocks: () => [] }
  }
  // Home: tile-type blocks (same filter as scriptGroups in useBlocks)
  return {
    name: 'Home',
    params: {},
    filterBlocks: (blocks) => blocks.filter(b => b.scriptType === 'tile'),
  }
}

const BLOCK_TYPE_COLOR: Record<string, string> = {
  confirmation: '#ff6b35',
  alert: '#ff3b30',
  prompt: '#007aff',
  chat_prompt: '#007aff',
  quick_reply: '#34c759',
  picker: '#5856d6',
  agent_session: '#af52de',
  session_event: '#af52de',
  start_session: '#5856d6',
  status: '#8e8e93',
  info_card: '#1c1c1e',
  icon_card: '#1c1c1e',
  countdown: '#ff9f0a',
  feed_item: '#30b0c7',
  activity_feed: '#30b0c7',
  compact_summary: '#30b0c7',
  progress: '#34c759',
  log: '#8e8e93',
  image: '#8e8e93',
  tile: '#007aff',
  toggle: '#34c759',
  multi_select: '#5856d6',
  list: '#5856d6',
  detail: '#1c1c1e',
  diagnostics: '#ff9f0a',
}

function highlightBlock(block: Block) {
  document.querySelectorAll('[data-block-id].inspector-highlighted, [data-script-id].inspector-highlighted')
    .forEach(el => el.classList.remove('inspector-highlighted'))
  document.querySelectorAll(`[data-block-id="${block.blockID}"]`)
    .forEach(el => el.classList.add('inspector-highlighted'))
  document.querySelectorAll(`[data-script-id="${block.scriptID}"]`)
    .forEach(el => el.classList.add('inspector-highlighted'))
}

function clearHighlight() {
  document.querySelectorAll('[data-block-id].inspector-highlighted, [data-script-id].inspector-highlighted')
    .forEach(el => el.classList.remove('inspector-highlighted'))
}

function BlockRow({ block }: { block: Block }) {
  const { showRedlines, focusedBlockID, setFocusedBlockID } = useRedlines()
  const color = BLOCK_TYPE_COLOR[block.blockType] ?? '#8e8e93'
  const shortID = block.blockID.slice(-8)
  const isFocused = focusedBlockID === block.blockID

  function handleClick() {
    if (!showRedlines) return
    setFocusedBlockID(isFocused ? null : block.blockID)
  }

  return (
    <div
      onMouseEnter={() => highlightBlock(block)}
      onMouseLeave={clearHighlight}
      onClick={handleClick}
      style={{
        borderLeft: `3px solid ${isFocused ? color : color}`,
        paddingLeft: 8,
        paddingTop: 5,
        paddingBottom: 5,
        marginBottom: 6,
        cursor: showRedlines ? 'pointer' : 'default',
        borderRadius: '0 4px 4px 0',
        transition: 'background 0.1s',
        background: isFocused ? `${color}20` : 'transparent',
        outline: isFocused ? `1.5px solid ${color}40` : 'none',
        outlineOffset: -1,
      }}
      onMouseOver={e => { if (!isFocused) (e.currentTarget as HTMLDivElement).style.background = `${color}14` }}
      onMouseOut={e => { if (!isFocused) (e.currentTarget as HTMLDivElement).style.background = 'transparent' }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, flexWrap: 'wrap' }}>
        <span style={{
          fontSize: 11,
          fontWeight: 600,
          color,
          fontFamily: 'ui-monospace, monospace',
          letterSpacing: 0.2,
        }}>
          {block.blockType}
        </span>
        {isFocused && (
          <span style={{
            fontSize: 9, fontWeight: 700, color,
            background: `${color}18`, borderRadius: 4,
            padding: '1px 4px', letterSpacing: 0.3,
          }}>
            FOCUSED
          </span>
        )}
        {block.requiresResponse === 1 && (
          <span style={{
            fontSize: 9,
            fontWeight: 700,
            color: '#ff6b35',
            background: 'rgba(255,107,53,0.12)',
            borderRadius: 4,
            padding: '1px 4px',
            letterSpacing: 0.3,
          }}>
            RESPONSE
          </span>
        )}
        {block.showsInInbox === 1 && (
          <span style={{
            fontSize: 9,
            fontWeight: 700,
            color: '#007aff',
            background: 'rgba(0,122,255,0.12)',
            borderRadius: 4,
            padding: '1px 4px',
            letterSpacing: 0.3,
          }}>
            INBOX
          </span>
        )}
      </div>
      <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.55)', marginTop: 1, fontFamily: 'ui-monospace, monospace' }}>
        {shortID}
      </div>
    </div>
  )
}

function ScriptSection({ scriptID: _scriptID, blocks }: { scriptID: string; blocks: Block[] }) {
  const first = blocks[0]
  const scriptName = first?.scriptName ?? 'Unknown Script'

  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{
        fontSize: 11,
        fontWeight: 700,
        color: 'rgba(0,0,0,0.8)',
        marginBottom: 5,
        display: 'flex',
        alignItems: 'center',
        gap: 5,
      }}>
        <span style={{ fontSize: 13 }}>
          {first?.scriptIcon ?? '📋'}
        </span>
        <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
          {scriptName}
        </span>
        <span style={{
          fontSize: 10,
          fontWeight: 600,
          color: 'rgba(0,0,0,0.35)',
          background: 'rgba(0,0,0,0.06)',
          borderRadius: 6,
          padding: '1px 5px',
        }}>
          {blocks.length}
        </span>
      </div>
      {blocks.map(b => (
        <BlockRow key={b.blockID} block={b} />
      ))}
    </div>
  )
}

function CopyAllButton({ blockID }: { blockID: string }) {
  const [copied, setCopied] = useState(false)

  function handleCopy() {
    const phoneEl = document.getElementById('phone-screen')
    if (!phoneEl) return
    const el = phoneEl.querySelector(`[data-block-id="${blockID}"]`) as HTMLElement | null
    if (!el) return
    const cs = getComputedStyle(el)
    const rect = el.getBoundingClientRect()
    const phoneRect = phoneEl.getBoundingClientRect()
    const scale = phoneRect.width / phoneEl.offsetWidth
    const data = {
      width: Math.round(rect.width / scale),
      height: Math.round(rect.height / scale),
      paddingTop: Math.round(parseFloat(cs.paddingTop) || 0),
      paddingRight: Math.round(parseFloat(cs.paddingRight) || 0),
      paddingBottom: Math.round(parseFloat(cs.paddingBottom) || 0),
      paddingLeft: Math.round(parseFloat(cs.paddingLeft) || 0),
      gap: (() => {
        const parent = el.parentElement
        if (!parent) return 0
        const pcs = getComputedStyle(parent)
        if (pcs.display !== 'flex' && pcs.display !== 'grid') return 0
        return Math.round(parseFloat(pcs.gap.split(' ')[0]) || 0)
      })(),
    }
    navigator.clipboard.writeText(JSON.stringify(data, null, 2)).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 400)
  }

  return (
    <button
      onClick={handleCopy}
      style={{
        fontSize: 9, fontWeight: 600,
        color: copied ? 'rgb(52,199,89)' : 'rgb(255,45,120)',
        background: copied ? 'rgba(52,199,89,0.1)' : 'rgba(255,45,120,0.1)',
        borderRadius: 4, padding: '1px 5px', letterSpacing: 0.3,
        border: 'none', cursor: 'pointer',
      }}
    >
      {copied ? 'copied!' : 'copy all'}
    </button>
  )
}

export default function UIInspectorPanel() {
  const location = useLocation()
  const { blocks, loading } = useBlocks()
  const { name: screenName, params, filterBlocks } = getScreenInfo(location.pathname)
  const { showRedlines, focusedBlockID, setFocusedBlockID } = useRedlines()

  // Clear focus when redlines turns off or screen changes
  useEffect(() => {
    if (!showRedlines) setFocusedBlockID(null)
  }, [showRedlines, setFocusedBlockID])

  useEffect(() => {
    setFocusedBlockID(null)
  }, [location.pathname, setFocusedBlockID])

  // Apply the same block filter the current screen uses
  const screenBlocks = filterBlocks(blocks)

  // Group filtered blocks by scriptID
  const grouped = screenBlocks.reduce<Record<string, Block[]>>((acc, block) => {
    if (!acc[block.scriptID]) acc[block.scriptID] = []
    acc[block.scriptID].push(block)
    return acc
  }, {})

  const scriptIDs = Object.keys(grouped)

  return (
    <div
      style={{
        width: 260,
        height: 844,
        flexShrink: 0,
        alignSelf: 'flex-start',
        display: 'flex',
        flexDirection: 'column',
        background: 'rgba(255,255,255,0.88)',
        backdropFilter: 'blur(16px)',
        WebkitBackdropFilter: 'blur(16px)',
        borderRadius: 14,
        border: '1px solid rgba(0,0,0,0.10)',
        boxShadow: '0 4px 20px rgba(0,0,0,0.08)',
        overflow: 'hidden',
        fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      }}
    >
      {/* Header */}
      <div style={{
        padding: '10px 14px 8px',
        borderBottom: '1px solid rgba(0,0,0,0.07)',
        background: 'rgba(0,0,0,0.02)',
      }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'rgba(0,0,0,0.4)', letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 6 }}>
          UI Inspector
        </div>

        {/* Screen name */}
        <div style={{ fontSize: 15, fontWeight: 700, color: 'rgba(0,0,0,0.85)', marginBottom: 2 }}>
          {screenName}
        </div>
        <div style={{ fontSize: 10, color: 'rgba(0,0,0,0.35)', fontFamily: 'ui-monospace, monospace' }}>
          {location.pathname}
        </div>

        {/* Route params */}
        {Object.keys(params).length > 0 && (
          <div style={{ marginTop: 7, display: 'flex', flexDirection: 'column', gap: 2 }}>
            {Object.entries(params).map(([k, v]) => (
              <div key={k} style={{ fontSize: 10, fontFamily: 'ui-monospace, monospace', color: 'rgba(0,0,0,0.5)' }}>
                <span style={{ color: '#5856d6', fontWeight: 600 }}>{k}</span>
                {': '}
                <span style={{ color: 'rgba(0,0,0,0.6)' }}>{v.length > 22 ? v.slice(0, 22) + '…' : v}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Blocks section */}
      <div style={{ flex: 1, padding: '10px 14px', overflowY: 'auto' }}>
        <div style={{
          fontSize: 11,
          fontWeight: 700,
          color: 'rgba(0,0,0,0.4)',
          letterSpacing: 0.8,
          textTransform: 'uppercase',
          marginBottom: 10,
          display: 'flex',
          alignItems: 'center',
          gap: 5,
        }}>
          Blocks
          {showRedlines && !focusedBlockID && (
            <span style={{ fontSize: 9, fontWeight: 600, color: 'rgb(255,45,120)', background: 'rgba(255,45,120,0.1)', borderRadius: 4, padding: '1px 5px', letterSpacing: 0.3, textTransform: 'none' }}>
              click to focus
            </span>
          )}
          {showRedlines && focusedBlockID && (
            <CopyAllButton blockID={focusedBlockID} />
          )}
          {!loading && (
            <span style={{
              fontSize: 10,
              fontWeight: 600,
              color: 'rgba(0,0,0,0.35)',
              background: 'rgba(0,0,0,0.06)',
              borderRadius: 6,
              padding: '1px 5px',
            }}>
              {screenBlocks.length}
            </span>
          )}
        </div>

        {loading && (
          <div style={{ fontSize: 12, color: 'rgba(0,0,0,0.35)', textAlign: 'center', paddingTop: 12 }}>
            Loading…
          </div>
        )}

        {!loading && screenBlocks.length === 0 && (
          <div style={{ fontSize: 12, color: 'rgba(0,0,0,0.3)', textAlign: 'center', paddingTop: 12 }}>
            No blocks
          </div>
        )}

        {!loading && scriptIDs.map(id => (
          <ScriptSection key={id} scriptID={id} blocks={grouped[id]} />
        ))}
      </div>
    </div>
  )
}
