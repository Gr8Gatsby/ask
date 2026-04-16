import { useEffect, useRef, useState, useCallback } from 'react'
import { useLocation } from 'react-router-dom'
import { useRedlines } from '../../lib/RedlinesContext'

// ---- Color map (mirrors UIInspectorPanel) ----

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
  info_card: '#636366',
  icon_card: '#636366',
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
  detail: '#636366',
  diagnostics: '#ff9f0a',
  'script-group': '#007aff',
}

const RL_STROKE = 'rgba(255,45,85,0.85)'

// ---- Measured element ----

interface MeasuredEl {
  id: string
  isNamedBlock: boolean   // true = has data-block-id / data-script-id
  blockType: string
  color: string
  // Clipped logical coords (clamped to phone bounds)
  x: number; y: number; w: number; h: number
  // Original unclipped logical coords (for focused annotations)
  ox: number; oy: number; ow: number; oh: number
  // Padding from getComputedStyle (logical px)
  paddingTop: number; paddingRight: number; paddingBottom: number; paddingLeft: number
  rowGap: number
  showGap: boolean
}

// ---- Element collection helpers ----

/** Generate a stable DOM-path key for elements without data-block-id */
function domKey(el: HTMLElement, root: HTMLElement): string {
  const parts: number[] = []
  let node: HTMLElement | null = el
  while (node && node !== root) {
    const parent: HTMLElement | null = node.parentElement
    if (!parent) break
    parts.unshift(Array.from(parent.children).indexOf(node))
    node = parent
  }
  return 'el-' + parts.join('.')
}

/** Returns true if the element has a visible surface worth annotating */
function isVisualEl(el: HTMLElement): boolean {
  const tag = el.tagName.toUpperCase()
  // Always annotate interactive elements
  if (['BUTTON', 'A', 'INPUT', 'SELECT', 'TEXTAREA'].includes(tag)) return true
  const cs = getComputedStyle(el)
  // Skip invisible elements
  if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0) return false
  // Has a non-transparent background color
  const bg = cs.backgroundColor
  if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') return true
  // Has a visible border
  if (parseFloat(cs.borderTopWidth) > 0 || parseFloat(cs.borderLeftWidth) > 0) return true
  return false
}

// ---- Measurement pass ----

function collectElements(): MeasuredEl[] {
  const phoneEl = document.getElementById('phone-screen')
  if (!phoneEl) return []

  const phoneRect = phoneEl.getBoundingClientRect()
  if (phoneRect.width === 0) return []

  const scale = phoneRect.width / phoneEl.offsetWidth
  const phoneLogW = phoneEl.offsetWidth
  const phoneLogH = phoneEl.offsetHeight

  // ── Phase 1: named blocks (data-block-id / data-script-id) ──────────────────
  // Keep outermost element per unique ID (existing deduplication logic)
  const namedMap = new Map<string, HTMLElement>()
  for (const el of Array.from(phoneEl.querySelectorAll('[data-block-id], [data-script-id]')) as HTMLElement[]) {
    const bid = el.getAttribute('data-block-id')
    const sid = el.getAttribute('data-script-id')
    const key = bid ? `b:${bid}` : `s:${sid}`
    let dominated = false
    let ancestor = el.parentElement
    while (ancestor && ancestor !== phoneEl) {
      if (bid && ancestor.getAttribute('data-block-id') === bid) { dominated = true; break }
      if (sid && ancestor.getAttribute('data-script-id') === sid) { dominated = true; break }
      ancestor = ancestor.parentElement
    }
    if (!dominated && !namedMap.has(key)) namedMap.set(key, el)
  }
  const namedSet = new Set(namedMap.values())

  // ── Phase 2: all other visual UI elements ────────────────────────────────────
  const visualEls: HTMLElement[] = []
  for (const el of Array.from(phoneEl.querySelectorAll('*')) as HTMLElement[]) {
    if (namedSet.has(el)) continue               // already captured as named block
    if (!isVisualEl(el)) continue
    const rect = el.getBoundingClientRect()
    const logW = rect.width / scale
    const logH = rect.height / scale
    if (logW < 20 || logH < 8) continue          // too small to be meaningful
    // Skip entirely outside phone
    if (rect.bottom < phoneRect.top || rect.top > phoneRect.bottom ||
        rect.right < phoneRect.left || rect.left > phoneRect.right) continue
    visualEls.push(el)
  }

  // ── Shared measurement function ──────────────────────────────────────────────
  const result: MeasuredEl[] = []

  const measureEl = (el: HTMLElement, id: string, isNamedBlock: boolean) => {
    const elRect = el.getBoundingClientRect()
    if (elRect.width === 0 || elRect.height === 0) return
    if (elRect.bottom < phoneRect.top || elRect.top > phoneRect.bottom ||
        elRect.right < phoneRect.left || elRect.left > phoneRect.right) return

    const blockType = el.getAttribute('data-block-type') ?? el.tagName.toLowerCase()
    const color = BLOCK_TYPE_COLOR[blockType] ?? '#8e8e93'

    const ox = (elRect.left - phoneRect.left) / scale
    const oy = (elRect.top - phoneRect.top) / scale
    const ow = elRect.width / scale
    const oh = elRect.height / scale

    const cx1 = Math.max(0, ox), cy1 = Math.max(0, oy)
    const cx2 = Math.min(phoneLogW, ox + ow), cy2 = Math.min(phoneLogH, oy + oh)
    if (cx2 - cx1 <= 0 || cy2 - cy1 <= 0) return

    const cs = getComputedStyle(el)
    const paddingTop    = parseFloat(cs.paddingTop)    || 0
    const paddingRight  = parseFloat(cs.paddingRight)  || 0
    const paddingBottom = parseFloat(cs.paddingBottom) || 0
    const paddingLeft   = parseFloat(cs.paddingLeft)   || 0

    let rowGap = 0, showGap = false
    const parent = el.parentElement
    if (parent) {
      const pcs = getComputedStyle(parent)
      if (pcs.display === 'flex' || pcs.display === 'grid') {
        const parsed = parseFloat(pcs.gap.split(' ')[0])
        if (!isNaN(parsed) && parsed > 0 && el.nextElementSibling) {
          rowGap = parsed; showGap = true
        }
      }
    }

    result.push({
      id, isNamedBlock, blockType, color,
      x: cx1, y: cy1, w: cx2 - cx1, h: cy2 - cy1,
      ox, oy, ow, oh,
      paddingTop, paddingRight, paddingBottom, paddingLeft,
      rowGap, showGap,
    })
  }

  // Measure named blocks
  for (const [, el] of namedMap) {
    const bid = el.getAttribute('data-block-id')
    const sid = el.getAttribute('data-script-id')
    measureEl(el, bid ?? sid ?? '', true)
  }

  // Measure visual UI elements (cap to avoid overload)
  const MAX_VISUAL = 150
  for (const el of visualEls.slice(0, MAX_VISUAL)) {
    measureEl(el, domKey(el, phoneEl), false)
  }

  return result
}

// ---- SVG helpers ----

function TypeLabel({ x, y, text, color }: { x: number; y: number; text: string; color: string }) {
  const pillW = text.length * 6.2 + 8
  const pillH = 16
  return (
    <g>
      <rect x={x} y={y} width={pillW} height={pillH} rx={4}
        fill={color} fillOpacity={0.15}
        stroke={color} strokeWidth={0.75} strokeOpacity={0.6}
      />
      <text x={x + 4} y={y + pillH / 2}
        dominantBaseline="middle"
        fill={color} fillOpacity={1}
        fontSize={10} fontWeight={600} fontFamily="ui-monospace, monospace"
        style={{ userSelect: 'none' }}
      >
        {text}
      </text>
    </g>
  )
}

function CopyLabel({ x, y, text, anchor = 'start', copyValue }: {
  x: number; y: number; text: string
  anchor?: 'start' | 'middle' | 'end'
  copyValue: string
}) {
  const [copied, setCopied] = useState(false)
  const pillW = text.length * 6.2 + 10
  const pillH = 18
  const pillX = anchor === 'middle' ? x - pillW / 2 : anchor === 'end' ? x - pillW : x

  function handleClick(e: React.MouseEvent) {
    e.stopPropagation()
    navigator.clipboard.writeText(copyValue).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 400)
  }

  return (
    <g onClick={handleClick} style={{ pointerEvents: 'auto', cursor: 'pointer' }}>
      <rect x={pillX} y={y - pillH / 2} width={pillW} height={pillH} rx={4}
        fill={copied ? 'rgba(52,199,89,0.85)' : 'rgba(25,25,25,0.88)'}
      />
      <text
        x={x} y={y}
        textAnchor={anchor} dominantBaseline="middle"
        fill="white" fontSize={10} fontWeight={500} fontFamily="ui-monospace, monospace"
        style={{ userSelect: 'none' }}
      >
        {text}
      </text>
    </g>
  )
}

function PaddingFills({ el }: { el: MeasuredEl }) {
  const { ox: x, oy: y, ow: w, oh: h, paddingTop: pt, paddingRight: pr, paddingBottom: pb, paddingLeft: pl } = el
  const fill = 'rgba(255,149,0,0.25)'
  return (
    <>
      {pt > 0 && <rect x={x} y={y} width={w} height={pt} fill={fill} />}
      {pb > 0 && <rect x={x} y={y + h - pb} width={w} height={pb} fill={fill} />}
      {pl > 0 && <rect x={x} y={y + pt} width={pl} height={h - pt - pb} fill={fill} />}
      {pr > 0 && <rect x={x + w - pr} y={y + pt} width={pr} height={h - pt - pb} fill={fill} />}
    </>
  )
}

function GapFill({ el }: { el: MeasuredEl }) {
  if (!el.showGap) return null
  return (
    <rect
      x={el.ox} y={el.oy + el.oh}
      width={el.ow} height={el.rowGap}
      fill="rgba(0,122,255,0.20)"
    />
  )
}

// Dimension line constants
const DIM_OFFSET = 20    // distance from element edge to the dimension line
const DIM_GAP = 3        // gap between element edge and extension line start
const DIM_OVERHANG = 5   // extension line extends this far past the dimension line

function DimensionLines({ el, side }: { el: MeasuredEl; side: 'left' | 'right' }) {
  const { ox: x, oy: y, ow: w, oh: h } = el
  const displayW = Math.round(w)
  const displayH = Math.round(h)

  // Width dimension line — above element
  // Extension lines run from (element edge + GAP) perpendicular up to (dim line + OVERHANG)
  const wDimY = y - DIM_OFFSET
  const wExtFrom = y - DIM_GAP            // extension line starts just above element edge
  const wExtTo = wDimY - DIM_OVERHANG     // extension line ends past the dimension line

  // Height dimension line — on annotation side
  // Extension lines run from (element edge + GAP) perpendicular out to (dim line + OVERHANG)
  const hDimX = side === 'left' ? x - DIM_OFFSET : x + w + DIM_OFFSET
  const hExtFrom = side === 'left' ? x - DIM_GAP : x + w + DIM_GAP
  const hExtTo   = side === 'left' ? hDimX - DIM_OVERHANG : hDimX + DIM_OVERHANG

  return (
    <>
      {/* ── Width ── */}
      {/* Extension lines — thin, project from element edges up through the dimension line */}
      <line x1={x}     y1={wExtFrom} x2={x}     y2={wExtTo} stroke={RL_STROKE} strokeWidth={0.75} />
      <line x1={x + w} y1={wExtFrom} x2={x + w} y2={wExtTo} stroke={RL_STROKE} strokeWidth={0.75} />
      {/* Dimension line — spans exactly element width */}
      <line x1={x} y1={wDimY} x2={x + w} y2={wDimY} stroke={RL_STROKE} strokeWidth={1} />
      {/* Label — above the dimension line */}
      <CopyLabel x={x + w / 2} y={wExtTo - 8} text={`${displayW}px`} anchor="middle" copyValue={`width: ${displayW}px`} />

      {/* ── Height ── */}
      {/* Extension lines — project from element top/bottom edges out through the dimension line */}
      <line x1={hExtFrom} y1={y}     x2={hExtTo} y2={y}     stroke={RL_STROKE} strokeWidth={0.75} />
      <line x1={hExtFrom} y1={y + h} x2={hExtTo} y2={y + h} stroke={RL_STROKE} strokeWidth={0.75} />
      {/* Dimension line — spans exactly element height */}
      <line x1={hDimX} y1={y} x2={hDimX} y2={y + h} stroke={RL_STROKE} strokeWidth={1} />
      {/* Label — beside the dimension line, beyond the overhang */}
      <CopyLabel
        x={side === 'left' ? hExtTo - 6 : hExtTo + 6}
        y={y + h / 2}
        text={`${displayH}px`}
        anchor={side === 'left' ? 'end' : 'start'}
        copyValue={`height: ${displayH}px`}
      />
    </>
  )
}

function MeasurementLabels({ el, side }: { el: MeasuredEl; side: 'left' | 'right' }) {
  const { ox: x, oy: y, ow: w, oh: h,
    paddingTop: pt, paddingRight: pr, paddingBottom: pb, paddingLeft: pl,
    rowGap: gap, showGap } = el

  const items: Array<{ text: string; value: string }> = []
  if (pt > 0) items.push({ text: `padding-top: ${Math.round(pt)}px`, value: `padding-top: ${Math.round(pt)}px` })
  if (pr > 0) items.push({ text: `padding-right: ${Math.round(pr)}px`, value: `padding-right: ${Math.round(pr)}px` })
  if (pb > 0) items.push({ text: `padding-bottom: ${Math.round(pb)}px`, value: `padding-bottom: ${Math.round(pb)}px` })
  if (pl > 0) items.push({ text: `padding-left: ${Math.round(pl)}px`, value: `padding-left: ${Math.round(pl)}px` })
  if (showGap && gap > 0) items.push({ text: `gap: ${Math.round(gap)}px`, value: `gap: ${Math.round(gap)}px` })

  if (items.length === 0) return null

  const labelH = 18
  const labelGap = 4
  const totalH = items.length * labelH + (items.length - 1) * labelGap
  const startY = y + (h - totalH) / 2

  const hDimX  = side === 'left' ? x - DIM_OFFSET : x + w + DIM_OFFSET
  const hExtTo = side === 'left' ? hDimX - DIM_OVERHANG : hDimX + DIM_OVERHANG
  const labelX = side === 'left' ? hExtTo - 6 : hExtTo + 6
  const anchor: 'start' | 'end' = side === 'left' ? 'end' : 'start'

  return (
    <>
      {items.map((item, i) => (
        <CopyLabel
          key={item.text}
          x={labelX}
          y={startY + i * (labelH + labelGap) + labelH / 2}
          text={item.text}
          anchor={anchor}
          copyValue={item.value}
        />
      ))}
    </>
  )
}

// ---- Main component ----

export default function RedlinesOverlay({ framePad }: { framePad: number }) {
  const { showRedlines, focusedBlockID, setFocusedBlockID, inspectorOpen } = useRedlines()
  const location = useLocation()
  const [elements, setElements] = useState<MeasuredEl[]>([])
  const pendingRaf = useRef<number | null>(null)

  const scheduleMeasure = useCallback(() => {
    if (pendingRaf.current !== null) cancelAnimationFrame(pendingRaf.current)
    pendingRaf.current = requestAnimationFrame(() => {
      pendingRaf.current = null
      setElements(collectElements())
    })
  }, [])

  // Set up observers
  useEffect(() => {
    if (!showRedlines) {
      setElements([])
      return
    }

    scheduleMeasure()

    const phoneEl = document.getElementById('phone-screen')
    if (!phoneEl) return

    const ro = new ResizeObserver(scheduleMeasure)
    ro.observe(phoneEl)

    const mo = new MutationObserver(scheduleMeasure)
    mo.observe(phoneEl, { childList: true, subtree: true })

    phoneEl.addEventListener('scroll', scheduleMeasure, { capture: true, passive: true })

    return () => {
      ro.disconnect()
      mo.disconnect()
      phoneEl.removeEventListener('scroll', scheduleMeasure, { capture: true })
      if (pendingRaf.current !== null) cancelAnimationFrame(pendingRaf.current)
    }
  }, [showRedlines, scheduleMeasure])

  // Re-measure on route change
  useEffect(() => {
    if (showRedlines) scheduleMeasure()
  }, [location.pathname, showRedlines, scheduleMeasure])

  if (!showRedlines || elements.length === 0) return null

  const focused = focusedBlockID ? elements.find(e => e.id === focusedBlockID) ?? null : null
  const side: 'left' | 'right' = inspectorOpen ? 'left' : 'right'

  return (
    <svg
      style={{
        position: 'absolute',
        top: framePad,
        left: framePad,
        width: 390,
        height: 844,
        overflow: 'visible',
        pointerEvents: 'none',
        zIndex: 20,
      }}
    >
      {/* Padding fills for focused block (drawn below outlines) */}
      {focused && <PaddingFills el={focused} />}
      {focused && <GapFill el={focused} />}

      {/* Outlines for all blocks */}
      {elements.map(el => {
        const isFocused = el.id === focusedBlockID
        const dimmed = !!focusedBlockID && !isFocused
        return (
          <g key={el.id}>
            <rect
              x={el.x} y={el.y} width={el.w} height={el.h}
              fill="none"
              stroke={RL_STROKE}
              strokeWidth={isFocused ? 2 : 1}
              strokeOpacity={dimmed ? 0.12 : isFocused ? 1 : 0.7}
              style={{ pointerEvents: 'auto', cursor: 'pointer' }}
              onClick={() => setFocusedBlockID(isFocused ? null : el.id)}
            />
            {/* Type label pill — named blocks only, all-blocks mode only */}
            {!focusedBlockID && el.isNamedBlock && (
              <TypeLabel x={el.x + 4} y={el.y + 4} text={el.blockType} color={el.color} />
            )}
          </g>
        )
      })}

      {/* Dimension lines and measurement labels for focused block */}
      {focused && <DimensionLines el={focused} side={side} />}
      {focused && <MeasurementLabels el={focused} side={side} />}
    </svg>
  )
}
