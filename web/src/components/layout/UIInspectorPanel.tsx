import { useLocation } from 'react-router-dom'
import { useState, useEffect, useCallback } from 'react'
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

// Per-screen structural layout descriptions — describes the component hierarchy,
// not the live data values, so it's useful as a design spec prompt.
const SCREEN_LAYOUT_DESCRIPTIONS: Record<string, (params: Record<string, string>, blockTypes: string[], scriptCount: number) => string> = {
  'Home': (_, blockTypes, scriptCount) => `
**Purpose:** Main dashboard. Shows one card per active script.

**Chrome:**
- Navigation bar: large title "Ask", no back button
- Tab bar (bottom): Home (selected) | Feed | Settings

**Content — Inset-grouped script list:**
- ${scriptCount} script card${scriptCount !== 1 ? 's' : ''}, each row contains:
  - Left: 28×28pt script icon (colored SVG or SF Symbol, rounded)
  - Center stack: script name (17pt semibold, primary) / status subtitle (13pt, secondary color)
  - Right: disclosure chevron (6×10pt, medium weight, secondary/45% opacity)
- Rows are separated by inset hairline dividers (starts at x=56pt, ends 16pt from right edge)
- List style: inset-grouped (rounded corners, card-like grouping)
- Block types driving cards: ${[...new Set(blockTypes)].join(', ') || 'tile'}
`.trim(),

  'Script Detail': ({ scriptID }, blockTypes) => `
**Purpose:** Detail view for a single script ("${scriptID}"). Shows all blocks emitted by this script.

**Chrome:**
- Navigation bar: back button + script name as title
- No tab bar (pushed onto nav stack)

**Content — sections:**
1. Script header: large icon (40pt) + name + description/status, full-width card
2. Sessions list (if any agent_session blocks): each row has status dot + session label + timestamp + chevron
   - Row height: ~44pt, separator at x=38pt from left
3. Status / info blocks rendered inline (status, info_card, tile, etc.)
4. Interactive blocks at top if present (confirmation, prompt, picker)

**Block types present:** ${[...new Set(blockTypes)].join(', ') || 'none'}
`.trim(),

  'Session Chat': ({ scriptID, sessionID }, blockTypes) => `
**Purpose:** Full-screen chat view for a Claude Code / agent session.

**Chrome:**
- Navigation bar: back button + session title
- No tab bar

**Content:**
- Scrollable message thread (top → bottom, newest at bottom)
- Each message bubble: role indicator + content + timestamp
- Text input bar pinned at bottom (multiline, send button)
- Session ID context: ${sessionID ?? '—'}
- Script: ${scriptID ?? '—'}

**Block types present:** ${[...new Set(blockTypes)].join(', ') || 'agent_session'}
`.trim(),

  'Task Feed': (_, blockTypes, scriptCount) => `
**Purpose:** Activity feed across all scripts — recent events in reverse-chronological order.

**Chrome:**
- Navigation bar: "Feed" title, filter controls
- Tab bar (bottom): Home | Feed (selected) | Settings

**Content — chronological event list:**
- Rows show: status dot (colored by script) + event description + script name + relative time
- No grouping by script — all events interleaved by time
- Pull-to-refresh supported
- ${scriptCount} script${scriptCount !== 1 ? 's' : ''} with activity shown

**Block types present:** ${[...new Set(blockTypes)].join(', ') || 'agent_session, session_event'}
`.trim(),

  'Task Thread': ({ taskID }) => `
**Purpose:** Thread view for a single task/session.

**Chrome:**
- Navigation bar: back + task title
- No tab bar

**Content:**
- Chronological list of events for task "${taskID ?? '—'}"
- Each row: event type icon + description + timestamp
- May include sub-threads or expandable detail rows
`.trim(),

  'Settings': () => `
**Purpose:** App configuration screen.

**Chrome:**
- Navigation bar: "Settings" title
- Tab bar (bottom): Home | Feed | Settings (selected)

**Content — inset-grouped settings list:**
- Sections with header labels (all caps, secondary color)
- Each row: label (17pt) + value or control on right + optional chevron
- Row separator: inset hairline (starts at x=16pt, ends 16pt from right)
- Standard iOS settings visual style
`.trim(),
}

// Read a handful of computed style values from a DOM element, formatted for the prompt
function inspectElement(selector: string): Record<string, string> | null {
  const el = document.querySelector<HTMLElement>(selector)
  if (!el) return null
  const s = window.getComputedStyle(el)
  const rect = el.getBoundingClientRect()
  return {
    background: s.backgroundColor,
    color: s.color,
    fontSize: s.fontSize,
    fontWeight: s.fontWeight,
    lineHeight: s.lineHeight,
    padding: s.padding,
    borderRadius: s.borderRadius,
    height: `${Math.round(rect.height)}px`,
    width: `${Math.round(rect.width)}px`,
  }
}

function fmtInspect(label: string, styles: Record<string, string> | null): string {
  if (!styles) return ''
  const relevant = Object.entries(styles)
    .filter(([, v]) => v && v !== 'none' && v !== 'normal' && v !== '0px' && v !== 'auto')
    .map(([k, v]) => `    ${k}: ${v}`)
    .join('\n')
  return relevant ? `  ${label}:\n${relevant}` : ''
}

function buildLayoutPrompt(
  screenName: string,
  pathname: string,
  params: Record<string, string>,
  screenBlocks: Block[],
  _allBlocks: Block[],
): string {
  const blockTypes = screenBlocks.map(b => b.blockType)
  const scriptIDs = [...new Set(screenBlocks.map(b => b.scriptID))]
  const descFn = SCREEN_LAYOUT_DESCRIPTIONS[screenName]
  const layoutDesc = descFn
    ? descFn(params, blockTypes, scriptIDs.length)
    : `Screen: ${screenName}\nRoute: ${pathname}\nBlocks: ${screenBlocks.length}`

  const lines: string[] = []
  lines.push(`## iOS Screen Layout — ${screenName}`)
  lines.push(`Route: \`${pathname}\``)
  lines.push('')
  lines.push(layoutDesc)

  // Live CSS values measured from the rendered DOM
  const domSamples: string[] = []
  const phoneScreen = inspectElement('#phone-screen')
  const scriptCard  = inspectElement('[data-inspect="script-card"]')
  const scriptRow   = inspectElement('[data-inspect="script-row"]')
  const rowTitle    = inspectElement('[data-inspect="script-row-title"]')
  const rowSubtitle = inspectElement('[data-inspect="script-row-subtitle"]')

  if (phoneScreen || scriptCard || scriptRow || rowTitle || rowSubtitle) {
    lines.push('')
    lines.push('**Live CSS — measured from rendered DOM:**')
    lines.push('```')
    if (phoneScreen) domSamples.push(fmtInspect('Phone screen (background, size)', phoneScreen))
    if (scriptCard)  domSamples.push(fmtInspect('Script card (bg, radius, padding)', scriptCard))
    if (scriptRow)   domSamples.push(fmtInspect('Script row button (padding, height)', scriptRow))
    if (rowTitle)    domSamples.push(fmtInspect('Row title text', rowTitle))
    if (rowSubtitle) domSamples.push(fmtInspect('Row subtitle text', rowSubtitle))
    lines.push(domSamples.filter(Boolean).join('\n'))
    lines.push('```')
  }

  // Block type schema reference — what each block type renders as in the UI
  const uniqueTypes = [...new Set(blockTypes)]
  if (uniqueTypes.length > 0) {
    lines.push('')
    lines.push('**Block type → UI component mapping:**')
    const TYPE_UI: Record<string, string> = {
      tile: 'Home screen card (icon + title + subtitle row)',
      status: 'Inline status row (icon + label + color dot)',
      info_card: 'Expandable card with key/value pairs',
      confirmation: 'Modal or inline prompt with action buttons',
      prompt: 'Text input card with submit button',
      chat_prompt: 'Chat-style input with context bubble',
      picker: 'Native dropdown / segmented selector',
      agent_session: 'Chat session row (expandable into SessionChatScreen)',
      session_event: 'Timeline event row in session thread',
      countdown: 'Live countdown label on tile and detail',
      alert: 'Transient banner (not persisted)',
      quick_reply: 'Inline reply chips',
    }
    for (const t of uniqueTypes) {
      lines.push(`- \`${t}\`: ${TYPE_UI[t] ?? 'custom block'}`)
    }
  }

  return lines.join('\n')
}

export default function UIInspectorPanel() {
  const location = useLocation()
  const { blocks, loading } = useBlocks()
  const { name: screenName, params, filterBlocks } = getScreenInfo(location.pathname)
  const { showRedlines, focusedBlockID, setFocusedBlockID } = useRedlines()
  const [selectedBlockID, setSelectedBlockID] = useState<string | null>(null)
  const [promptCopied, setPromptCopied] = useState(false)
  const [screenshotState, setScreenshotState] = useState<'idle' | 'capturing' | 'copied'>('idle')
  const { setCleanView } = useRedlines()

  useEffect(() => { setSelectedBlockID(null) }, [location.pathname])
  useEffect(() => { if (!showRedlines) setFocusedBlockID(null) }, [showRedlines, setFocusedBlockID])
  useEffect(() => { setFocusedBlockID(null) }, [location.pathname, setFocusedBlockID])

  const screenBlocks = filterBlocks(blocks)

  const captureScreenshot = useCallback(async () => {
    setScreenshotState('capturing')
    try {
      // getDisplayMedia captures actual rendered pixels — no DOM-to-canvas conversion.
      // preferCurrentTab pre-selects this tab in Chrome so the user just clicks "Share".
      const stream = await (navigator.mediaDevices as MediaDevices & {
        getDisplayMedia(c?: object): Promise<MediaStream>
      }).getDisplayMedia({
        video: { displaySurface: 'browser' },
        preferCurrentTab: true,
      })

      // Draw one frame from the stream then stop immediately
      const video = document.createElement('video')
      video.srcObject = stream
      video.muted = true
      await new Promise<void>(resolve => { video.onloadedmetadata = () => resolve() })
      await video.play()

      const track = stream.getVideoTracks()[0]
      const { width: capW = window.innerWidth, height: capH = window.innerHeight } = track.getSettings()

      // Map CSS viewport coordinates → capture pixel coordinates
      const scaleX = capW / window.innerWidth
      const scaleY = capH / window.innerHeight

      // Crop to the phone frame element
      const frame = document.getElementById('phone-frame')
      const rect = frame?.getBoundingClientRect()

      const canvas = document.createElement('canvas')
      if (rect) {
        canvas.width  = Math.round(rect.width  * scaleX)
        canvas.height = Math.round(rect.height * scaleY)
        canvas.getContext('2d')!.drawImage(
          video,
          Math.round(rect.left * scaleX), Math.round(rect.top * scaleY),
          canvas.width, canvas.height,
          0, 0, canvas.width, canvas.height,
        )
      } else {
        // Fallback: full viewport
        canvas.width = capW; canvas.height = capH
        canvas.getContext('2d')!.drawImage(video, 0, 0)
      }

      video.pause()
      stream.getTracks().forEach(t => t.stop())

      canvas.toBlob(async (blob) => {
        if (!blob) { setScreenshotState('idle'); return }
        try {
          await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
          setScreenshotState('copied')
          setTimeout(() => setScreenshotState('idle'), 2000)
        } catch {
          const url = URL.createObjectURL(blob)
          const a = document.createElement('a')
          a.href = url
          a.download = `ask-${screenName.toLowerCase().replace(/\s+/g, '-')}.png`
          a.click()
          URL.revokeObjectURL(url)
          setScreenshotState('idle')
        }
      }, 'image/png')
    } catch (e) {
      // User cancelled the share dialog or browser doesn't support it
      console.warn('screenshot cancelled or unsupported', e)
      setScreenshotState('idle')
    }
  }, [screenName])

  function copyPrompt() {
    const text = buildLayoutPrompt(screenName, location.pathname, params, screenBlocks, blocks)
    navigator.clipboard.writeText(text).catch(() => {})
    setPromptCopied(true)
    setTimeout(() => setPromptCopied(false), 1500)
  }


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
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.35)', letterSpacing: 0.8, textTransform: 'uppercase' }}>
            UI Inspector
          </div>
          <div style={{ display: 'flex', gap: 4 }}>
            <button
              onClick={copyPrompt}
              title="Copy layout prompt for Claude"
              style={{
                fontSize: 10, fontWeight: 600, cursor: 'pointer', border: 'none', borderRadius: 5,
                padding: '3px 7px',
                color: promptCopied ? 'rgb(52,199,89)' : 'rgba(0,0,0,0.5)',
                background: promptCopied ? 'rgba(52,199,89,0.1)' : 'rgba(0,0,0,0.07)',
                transition: 'all 0.15s',
                display: 'flex', alignItems: 'center', gap: 3,
              }}
            >
              <span style={{ fontSize: 9 }}>{promptCopied ? '✓' : '⌘'}</span>
              {promptCopied ? 'copied!' : 'copy prompt'}
            </button>
            <button
              onClick={captureScreenshot}
              title="Copy screenshot to clipboard"
              disabled={screenshotState === 'capturing'}
              style={{
                fontSize: 10, fontWeight: 600,
                cursor: screenshotState === 'capturing' ? 'default' : 'pointer',
                border: 'none', borderRadius: 5, padding: '3px 7px',
                color: screenshotState === 'copied' ? 'rgb(52,199,89)' : 'rgba(0,0,0,0.5)',
                background: screenshotState === 'copied' ? 'rgba(52,199,89,0.1)' : 'rgba(0,0,0,0.07)',
                transition: 'all 0.15s', display: 'flex', alignItems: 'center', gap: 3,
              }}
            >
              <span style={{ fontSize: 9 }}>
                {screenshotState === 'capturing' ? '…' : screenshotState === 'copied' ? '✓' : '📷'}
              </span>
              {screenshotState === 'copied' ? 'copied!' : screenshotState === 'capturing' ? 'capturing…' : 'screenshot'}
            </button>
            <button
              onClick={() => setCleanView(true)}
              title="Clean view for manual screenshot (Esc to exit)"
              style={{
                fontSize: 10, fontWeight: 600, cursor: 'pointer',
                border: 'none', borderRadius: 5, padding: '3px 7px',
                color: 'rgba(0,0,0,0.5)', background: 'rgba(0,0,0,0.07)',
                display: 'flex', alignItems: 'center', gap: 3,
              }}
            >
              <span style={{ fontSize: 9 }}>⛶</span>
            </button>
          </div>
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
