import { useLocation } from 'react-router-dom'
import { useState, useEffect } from 'react'
import { useBlocks } from '../../lib/useBlocks'
import { useRedlines } from '../../lib/RedlinesContext'
import ScriptIcon from '../shared/ScriptIcon'
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
  // Home: one tile block per script group drives the card.
  // Inbox blocks (quick_reply / confirmation with showsInInbox=1) appear inline.
  // Everything else (status, agent_session, picker, etc.) only renders inside Script Detail.
  return {
    name: 'Home',
    params: {},
    filterBlocks: (blocks) => blocks.filter(b =>
      b.scriptType === 'tile' && (
        b.blockType === 'tile' ||
        b.showsInInbox === 1
      )
    ),
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

/** Highlight the specific block element AND its containing script-group card */
function highlightBlock(block: Block) {
  document.querySelectorAll('[data-block-id].inspector-highlighted, [data-script-id].inspector-highlighted')
    .forEach(el => el.classList.remove('inspector-highlighted'))

  const blockEls = document.querySelectorAll(`[data-block-id="${block.blockID}"]`)
  if (blockEls.length > 0) {
    blockEls.forEach(el => el.classList.add('inspector-highlighted'))
    // Also highlight the containing script-group card so context is clear
    document.querySelectorAll(`[data-script-id="${block.scriptID}"]`)
      .forEach(el => el.classList.add('inspector-highlighted'))
  } else {
    // Block not individually wrapped in DOM — highlight only the containing script-group card
    document.querySelectorAll(`[data-script-id="${block.scriptID}"]`)
      .forEach(el => el.classList.add('inspector-highlighted'))
  }
}

function clearHighlight() {
  document.querySelectorAll('[data-block-id].inspector-highlighted, [data-script-id].inspector-highlighted')
    .forEach(el => el.classList.remove('inspector-highlighted'))
}

// ---- Compact block list row ----

function BlockListRow({ block, onSelect, isSelected }: {
  block: Block
  onSelect: (id: string | null) => void
  isSelected: boolean
}) {
  const { showRedlines, setFocusedBlockID } = useRedlines()
  const color = BLOCK_TYPE_COLOR[block.blockType] ?? '#8e8e93'

  // Apply persistent DOM highlight when this row is selected; clear when deselected
  useEffect(() => {
    if (isSelected) {
      highlightBlock(block)
      return () => clearHighlight()
    }
  }, [isSelected, block])

  function handleClick() {
    onSelect(isSelected ? null : block.blockID)
    if (showRedlines) setFocusedBlockID(isSelected ? null : block.blockID)
  }

  return (
    <div
      onMouseEnter={() => highlightBlock(block)}
      onMouseLeave={() => { if (!isSelected) clearHighlight() }}
      onClick={handleClick}
      style={{
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '5px 14px',
        cursor: 'pointer',
        background: isSelected ? `${color}18` : 'transparent',
        borderLeft: `3px solid ${isSelected ? color : 'transparent'}`,
        transition: 'background 0.1s',
      }}
      onMouseOver={e => { if (!isSelected) (e.currentTarget as HTMLDivElement).style.background = 'rgba(0,0,0,0.04)' }}
      onMouseOut={e => { if (!isSelected) (e.currentTarget as HTMLDivElement).style.background = 'transparent' }}
    >
      {/* Color dot */}
      <div style={{ width: 6, height: 6, borderRadius: '50%', background: color, flexShrink: 0 }} />

      {/* Block type */}
      <span style={{
        fontSize: 12, fontWeight: 600, color: isSelected ? color : 'rgba(0,0,0,0.75)',
        fontFamily: 'ui-monospace, monospace', flex: 1,
        overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
      }}>
        {block.blockType}
      </span>

      {/* Badges */}
      <div style={{ display: 'flex', gap: 3, flexShrink: 0 }}>
        {block.requiresResponse === 1 && (
          <span style={{ fontSize: 8, fontWeight: 700, color: '#ff6b35', background: 'rgba(255,107,53,0.12)', borderRadius: 3, padding: '1px 3px' }}>R</span>
        )}
        {block.showsInInbox === 1 && (
          <span style={{ fontSize: 8, fontWeight: 700, color: '#007aff', background: 'rgba(0,122,255,0.12)', borderRadius: 3, padding: '1px 3px' }}>I</span>
        )}
      </div>
    </div>
  )
}

// ---- Script group header ----

function ScriptGroupHeader({ blocks, allBlocks }: { blocks: Block[]; allBlocks: Block[] }) {
  const scriptID = blocks[0]?.scriptID
  // Use first block from the FULL blocks list for this script — icon data may only be on
  // block types that don't pass the current screen filter (e.g. tile vs status)
  const iconSource = allBlocks.find(b => b.scriptID === scriptID && (b.scriptIconSVG || b.scriptIconData || b.scriptIcon))
    ?? blocks[0]
  const scriptName = blocks[0]?.scriptName ?? 'Unknown'
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 6,
      padding: '8px 14px 4px',
    }}>
      <ScriptIcon
        scriptIconSVG={iconSource?.scriptIconSVG}
        scriptIconData={iconSource?.scriptIconData}
        scriptIcon={iconSource?.scriptIcon}
        scriptName={scriptName}
        size={14}
        svgColor="rgba(0,0,0,0.75)"
      />
      <span style={{
        fontSize: 11, fontWeight: 700, color: 'rgba(0,0,0,0.6)',
        flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
      }}>
        {scriptName}
      </span>
      <span style={{
        fontSize: 10, fontWeight: 600, color: 'rgba(0,0,0,0.3)',
        background: 'rgba(0,0,0,0.05)', borderRadius: 5, padding: '0 4px',
      }}>
        {blocks.length}
      </span>
    </div>
  )
}

// ---- JSON viewer ----

// Light-background JSON token colors (high contrast on white)
const J = {
  key:       '#0055b3',   // strong blue
  string:    '#b24000',   // burnt orange
  number:    '#1a7f37',   // green
  boolean:   '#7c3aed',   // purple
  null:      '#6b7280',   // gray
  bracket:   'rgba(0,0,0,0.55)',
  comma:     'rgba(0,0,0,0.4)',
  toggle:    'rgba(0,0,0,0.4)',
  collapsed: 'rgba(0,0,0,0.35)',
}

function JsonToken({ value }: { value: unknown }) {
  const [open, setOpen] = useState(true)

  if (value === null) return <span style={{ color: J.null }}>null</span>
  if (typeof value === 'boolean') return <span style={{ color: J.boolean }}>{String(value)}</span>
  if (typeof value === 'number') return <span style={{ color: J.number }}>{value}</span>
  if (typeof value === 'string') {
    const MAX = 120
    if (value.length > MAX) return <StringTruncated value={value} max={MAX} />
    return <span style={{ color: J.string }}>"{value}"</span>
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return <span style={{ color: J.bracket }}>[]</span>
    return (
      <span>
        <button onClick={() => setOpen(v => !v)} style={{ background: 'none', border: 'none', cursor: 'pointer', padding: '0 2px 0 0', color: J.toggle, fontSize: 10 }}>
          {open ? '▾' : '▸'}
        </button>
        {open ? (
          <span>
            <span style={{ color: J.bracket }}>[</span>
            <div style={{ paddingLeft: 16 }}>
              {value.map((item, i) => (
                <div key={i}><JsonToken value={item} />{i < value.length - 1 ? <span style={{ color: J.comma }}>,</span> : ''}</div>
              ))}
            </div>
            <span style={{ color: J.bracket }}>]</span>
          </span>
        ) : (
          <span style={{ color: J.collapsed }}>[{value.length} items]</span>
        )}
      </span>
    )
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
    if (entries.length === 0) return <span style={{ color: J.bracket }}>{'{}'}</span>
    return (
      <span>
        <button onClick={() => setOpen(v => !v)} style={{ background: 'none', border: 'none', cursor: 'pointer', padding: '0 2px 0 0', color: J.toggle, fontSize: 10 }}>
          {open ? '▾' : '▸'}
        </button>
        {open ? (
          <span>
            <span style={{ color: J.bracket }}>{'{'}</span>
            <div style={{ paddingLeft: 16 }}>
              {entries.map(([k, v], i) => (
                <div key={k}>
                  <span style={{ color: J.key }}>"{k}"</span>
                  <span style={{ color: J.comma }}>: </span>
                  <JsonToken value={v} />
                  {i < entries.length - 1 ? <span style={{ color: J.comma }}>,</span> : ''}
                </div>
              ))}
            </div>
            <span style={{ color: J.bracket }}>{'}'}</span>
          </span>
        ) : (
          <span style={{ color: J.collapsed }}>{'{…}'}</span>
        )}
      </span>
    )
  }
  return <span>{String(value)}</span>
}

function StringTruncated({ value, max }: { value: string; max: number }) {
  const [expanded, setExpanded] = useState(false)
  return (
    <span style={{ color: J.string }}>
      "{expanded ? value : value.slice(0, max) + '…'}"{' '}
      <button
        onClick={() => setExpanded(v => !v)}
        style={{ fontSize: 9, color: 'rgba(0,0,0,0.4)', background: 'rgba(0,0,0,0.07)', border: 'none', borderRadius: 3, cursor: 'pointer', padding: '1px 4px' }}
      >
        {expanded ? 'less' : 'more'}
      </button>
    </span>
  )
}

function BlockPayloadPanel({ block, onClose }: { block: Block; onClose: () => void }) {
  const [copied, setCopied] = useState(false)
  const color = BLOCK_TYPE_COLOR[block.blockType] ?? '#8e8e93'
  let parsed: unknown = null
  let parseError = false
  try { parsed = JSON.parse(block.payload) } catch { parseError = true }

  function copyPayload() {
    navigator.clipboard.writeText(block.payload).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 400)
  }

  return (
    <div style={{ borderTop: '1px solid rgba(0,0,0,0.07)', flexShrink: 0, display: 'flex', flexDirection: 'column' }}>
      {/* Section header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '8px 14px 6px', background: 'rgba(0,0,0,0.02)' }}>
        <div style={{ width: 7, height: 7, borderRadius: '50%', background: color, flexShrink: 0 }} />
        <span style={{ fontSize: 12, fontWeight: 700, color: 'rgba(0,0,0,0.75)', fontFamily: 'ui-monospace, monospace', flex: 1 }}>
          {block.blockType}
        </span>
        <span style={{ fontSize: 10, color: 'rgba(0,0,0,0.3)', fontFamily: 'ui-monospace, monospace' }}>
          {block.blockID.slice(-8)}
        </span>
        <button
          onClick={copyPayload}
          style={{ fontSize: 9, fontWeight: 600, color: copied ? 'rgb(52,199,89)' : 'rgba(0,0,0,0.4)', background: copied ? 'rgba(52,199,89,0.1)' : 'rgba(0,0,0,0.06)', border: 'none', borderRadius: 4, padding: '2px 6px', cursor: 'pointer' }}
        >
          {copied ? 'copied' : 'copy'}
        </button>
        <button
          onClick={onClose}
          style={{ fontSize: 14, lineHeight: 1, color: 'rgba(0,0,0,0.3)', background: 'none', border: 'none', cursor: 'pointer', padding: '0 2px' }}
        >
          ×
        </button>
      </div>

      {/* JSON tree */}
      <div style={{
        maxHeight: 300, overflowY: 'auto',
        padding: '8px 14px 14px',
        fontSize: 12, lineHeight: 1.7,
        fontFamily: 'ui-monospace, monospace',
        color: 'rgba(0,0,0,0.75)',
        background: 'rgba(0,0,0,0.02)',
        scrollbarWidth: 'none',
      }}>
        {parseError
          ? <span style={{ color: '#ff3b30', fontSize: 10 }}>{block.payload}</span>
          : <JsonToken value={parsed} />
        }
      </div>
    </div>
  )
}

export default function UIInspectorPanel() {
  const location = useLocation()
  const { blocks, loading } = useBlocks()
  const { name: screenName, params, filterBlocks } = getScreenInfo(location.pathname)
  const { showRedlines, focusedBlockID, setFocusedBlockID } = useRedlines()
  const [selectedBlockID, setSelectedBlockID] = useState<string | null>(null)

  useEffect(() => { setSelectedBlockID(null) }, [location.pathname])
  useEffect(() => { if (!showRedlines) setFocusedBlockID(null) }, [showRedlines, setFocusedBlockID])
  useEffect(() => { setFocusedBlockID(null) }, [location.pathname, setFocusedBlockID])

  const screenBlocks = filterBlocks(blocks)
  const grouped = screenBlocks.reduce<Record<string, Block[]>>((acc, block) => {
    if (!acc[block.scriptID]) acc[block.scriptID] = []
    acc[block.scriptID].push(block)
    return acc
  }, {})
  const scriptIDs = Object.keys(grouped)

  // Active selection: local click takes priority, then redlines focus
  const activeBlockID = selectedBlockID ?? focusedBlockID
  const selectedBlock = activeBlockID ? blocks.find(b => b.blockID === activeBlockID) ?? null : null

  function handleSelect(id: string | null) {
    setSelectedBlockID(id)
    if (showRedlines) setFocusedBlockID(id)
  }

  return (
    <div style={{
      width: 320,
      maxHeight: 'calc(100vh - 120px)',
      flexShrink: 0,
      display: 'flex',
      flexDirection: 'column',
      background: 'rgba(255,255,255,0.92)',
      backdropFilter: 'blur(16px)',
      WebkitBackdropFilter: 'blur(16px)',
      borderRadius: 14,
      border: '1px solid rgba(0,0,0,0.10)',
      boxShadow: '0 4px 20px rgba(0,0,0,0.08)',
      overflow: 'hidden',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
    }}>

      {/* ── Header ── */}
      <div style={{ padding: '10px 14px 8px', borderBottom: '1px solid rgba(0,0,0,0.07)', background: 'rgba(0,0,0,0.02)', flexShrink: 0 }}>
        <div style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.35)', letterSpacing: 0.8, textTransform: 'uppercase', marginBottom: 4 }}>
          UI Inspector
        </div>
        <div style={{ fontSize: 15, fontWeight: 700, color: 'rgba(0,0,0,0.85)', marginBottom: 1 }}>{screenName}</div>
        <div style={{ fontSize: 10, color: 'rgba(0,0,0,0.35)', fontFamily: 'ui-monospace, monospace' }}>{location.pathname}</div>
        {Object.keys(params).length > 0 && (
          <div style={{ marginTop: 6, display: 'flex', flexDirection: 'column', gap: 2 }}>
            {Object.entries(params).map(([k, v]) => (
              <div key={k} style={{ fontSize: 10, fontFamily: 'ui-monospace, monospace', color: 'rgba(0,0,0,0.5)' }}>
                <span style={{ color: '#5856d6', fontWeight: 600 }}>{k}</span>{': '}
                <span style={{ color: 'rgba(0,0,0,0.6)' }}>{v.length > 22 ? v.slice(0, 22) + '…' : v}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* ── Block list (scrollable, shrinks when detail is open) ── */}
      <div style={{ flex: 1, overflowY: 'auto', scrollbarWidth: 'none', paddingBottom: 6 }}>
        {/* Section label */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 5, padding: '8px 14px 4px' }}>
          <span style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.35)', letterSpacing: 0.8, textTransform: 'uppercase' }}>
            Blocks
          </span>
          {!loading && (
            <span style={{ fontSize: 10, fontWeight: 600, color: 'rgba(0,0,0,0.3)', background: 'rgba(0,0,0,0.05)', borderRadius: 5, padding: '0 4px' }}>
              {screenBlocks.length}
            </span>
          )}
          {!selectedBlock && (
            <span style={{ fontSize: 9, color: 'rgba(0,0,0,0.3)', marginLeft: 2 }}>tap to inspect</span>
          )}
        </div>

        {loading && <div style={{ fontSize: 12, color: 'rgba(0,0,0,0.3)', textAlign: 'center', padding: 16 }}>Loading…</div>}
        {!loading && screenBlocks.length === 0 && <div style={{ fontSize: 12, color: 'rgba(0,0,0,0.3)', textAlign: 'center', padding: 16 }}>No blocks</div>}

        {!loading && scriptIDs.map(id => (
          <div key={id}>
            <ScriptGroupHeader blocks={grouped[id]} allBlocks={blocks} />
            {grouped[id].map(b => (
              <BlockListRow key={b.blockID} block={b} onSelect={handleSelect} isSelected={activeBlockID === b.blockID} />
            ))}
          </div>
        ))}
      </div>

      {/* ── Block detail / payload ── */}
      {selectedBlock && <BlockPayloadPanel block={selectedBlock} onClose={() => handleSelect(null)} />}
    </div>
  )
}
