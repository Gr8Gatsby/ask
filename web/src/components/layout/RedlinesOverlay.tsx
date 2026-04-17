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

/** Inline W×H label centered on a non-named visual element */
function SizeLabel({ el }: { el: MeasuredEl }) {
  const text = `${Math.round(el.ow)}×${Math.round(el.oh)}`
  const cx = el.ox + el.ow / 2
  const cy = el.oy + el.oh / 2
  const pillW = text.length * 5.5 + 8
  const pillH = 14
  // Don't render if element is too small to fit the label
  if (el.ow < pillW + 4 || el.oh < pillH + 4) return null
  return (
    <g pointerEvents="none">
      <rect x={cx - pillW / 2} y={cy - pillH / 2} width={pillW} height={pillH} rx={3}
        fill="rgba(0,0,0,0.62)"
      />
      <text x={cx} y={cy} textAnchor="middle" dominantBaseline="middle"
        fill="rgba(255,255,255,0.88)" fontSize={8} fontWeight={600}
        fontFamily="ui-monospace, monospace" style={{ userSelect: 'none' }}
      >
        {text}
      </text>
    </g>
  )
}

/** Blue spacing brackets between vertically adjacent named blocks */
function SpacingAnnotations({ elements }: { elements: MeasuredEl[] }) {
  const named = [...elements.filter(el => el.isNamedBlock)].sort((a, b) => a.oy - b.oy)
  const SPACE_C = 'rgba(0,122,255,0.9)'
  const FOOT = 10

  const spacers: Array<{ y1: number; y2: number; cx: number; dist: number }> = []
  for (let i = 0; i < named.length - 1; i++) {
    const a = named[i], b = named[i + 1]
    const gap = b.oy - (a.oy + a.oh)
    if (gap <= 0) continue
    // Only annotate if elements horizontally overlap
    const xOverlap = Math.min(a.ox + a.ow, b.ox + b.ow) - Math.max(a.ox, b.ox)
    if (xOverlap < 16) continue
    const cx = Math.max(a.ox, b.ox) + xOverlap / 2
    spacers.push({ y1: a.oy + a.oh, y2: b.oy, cx, dist: Math.round(gap) })
  }

  return (
    <>
      {spacers.map((s, i) => {
        const midY = (s.y1 + s.y2) / 2
        const labelW = String(s.dist).length * 5.5 + 14
        return (
          <g key={i} pointerEvents="none">
            <line x1={s.cx} y1={s.y1} x2={s.cx} y2={s.y2} stroke={SPACE_C} strokeWidth={1} />
            <line x1={s.cx - FOOT} y1={s.y1} x2={s.cx + FOOT} y2={s.y1} stroke={SPACE_C} strokeWidth={1} />
            <line x1={s.cx - FOOT} y1={s.y2} x2={s.cx + FOOT} y2={s.y2} stroke={SPACE_C} strokeWidth={1} />
            <rect x={s.cx - labelW / 2} y={midY - 8} width={labelW} height={16} rx={4}
              fill="rgba(0,122,255,0.88)" />
            <text x={s.cx} y={midY} textAnchor="middle" dominantBaseline="middle"
              fill="white" fontSize={8} fontWeight={600}
              fontFamily="ui-monospace, monospace" style={{ userSelect: 'none' }}
            >
              {s.dist}px
            </text>
          </g>
        )
      })}
    </>
  )
}

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

// ---- Dimension rail constants ----
// Width: extension lines go DOWN to a rail below the phone screen.
// Height: extension lines go LEFT to a rail left of the phone screen.
// This gives the architectural look with lines going to the far edges.
const RAIL_BOTTOM = 864   // width dim lines — just below the 844px phone screen
const RAIL_LEFT   = -18   // height dim lines — to the left of the phone screen
const DIM_TICK    = 5     // half-length of tick marks at dimension line endpoints

/** Always-on architectural dimension lines: extension lines go to the bottom and left margin rails */
function DimensionLines({ el }: { el: MeasuredEl }) {
  const { ox: x, oy: y, ow: w, oh: h } = el
  const dw = Math.round(w)
  const dh = Math.round(h)

  return (
    <g pointerEvents="none">
      {/* ── Width — extension lines go DOWN from element bottom to RAIL_BOTTOM ── */}
      <line x1={x}     y1={y + h} x2={x}     y2={RAIL_BOTTOM} stroke={RL_STROKE} strokeWidth={0.5} strokeOpacity={0.5} />
      <line x1={x + w} y1={y + h} x2={x + w} y2={RAIL_BOTTOM} stroke={RL_STROKE} strokeWidth={0.5} strokeOpacity={0.5} />
      {/* Dimension line at the bottom rail */}
      <line x1={x} y1={RAIL_BOTTOM} x2={x + w} y2={RAIL_BOTTOM} stroke={RL_STROKE} strokeWidth={1} strokeOpacity={0.9} />
      {/* Tick marks */}
      <line x1={x}     y1={RAIL_BOTTOM - DIM_TICK} x2={x}     y2={RAIL_BOTTOM + DIM_TICK} stroke={RL_STROKE} strokeWidth={1} strokeOpacity={0.9} />
      <line x1={x + w} y1={RAIL_BOTTOM - DIM_TICK} x2={x + w} y2={RAIL_BOTTOM + DIM_TICK} stroke={RL_STROKE} strokeWidth={1} strokeOpacity={0.9} />
      {/* Label below the rail */}
      <text x={x + w / 2} y={RAIL_BOTTOM + 14}
        textAnchor="middle" dominantBaseline="auto"
        fill={RL_STROKE} fillOpacity={0.95}
        fontSize={9} fontWeight={600} fontFamily="ui-monospace, monospace"
        style={{ userSelect: 'none' }}
      >
        {dw}px
      </text>

      {/* ── Height — extension lines go LEFT from element left edge to RAIL_LEFT ── */}
      <line x1={x} y1={y}     x2={RAIL_LEFT} y2={y}     stroke={RL_STROKE} strokeWidth={0.5} strokeOpacity={0.5} />
      <line x1={x} y1={y + h} x2={RAIL_LEFT} y2={y + h} stroke={RL_STROKE} strokeWidth={0.5} strokeOpacity={0.5} />
      {/* Dimension line at the left rail */}
      <line x1={RAIL_LEFT} y1={y} x2={RAIL_LEFT} y2={y + h} stroke={RL_STROKE} strokeWidth={1} strokeOpacity={0.9} />
      {/* Tick marks */}
      <line x1={RAIL_LEFT - DIM_TICK} y1={y}     x2={RAIL_LEFT + DIM_TICK} y2={y}     stroke={RL_STROKE} strokeWidth={1} strokeOpacity={0.9} />
      <line x1={RAIL_LEFT - DIM_TICK} y1={y + h} x2={RAIL_LEFT + DIM_TICK} y2={y + h} stroke={RL_STROKE} strokeWidth={1} strokeOpacity={0.9} />
      {/* Label to the left of the rail */}
      <text x={RAIL_LEFT - 9} y={y + h / 2}
        textAnchor="end" dominantBaseline="middle"
        fill={RL_STROKE} fillOpacity={0.95}
        fontSize={9} fontWeight={600} fontFamily="ui-monospace, monospace"
        style={{ userSelect: 'none' }}
      >
        {dh}px
      </text>
    </g>
  )
}

// ---- Main component ----

export default function RedlinesOverlay({ framePad }: { framePad: number }) {
  const { showRedlines, focusedBlockID, setFocusedBlockID, showSpacing, showAllDims } = useRedlines()
  const focusedBlockIDRef = useRef<string | null>(null)
  const location = useLocation()
  const [elements, setElements] = useState<MeasuredEl[]>([])
  const pendingRaf = useRef<number | null>(null)
  const elementsRef = useRef<MeasuredEl[]>([])

  // Keep refs in sync so capture-phase handler always sees fresh data
  useEffect(() => { elementsRef.current = elements }, [elements])
  useEffect(() => { focusedBlockIDRef.current = focusedBlockID }, [focusedBlockID])

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

  // Capture-phase click interceptor: DevTools inspect mode
  useEffect(() => {
    if (!showRedlines) return
    const phoneEl = document.getElementById('phone-screen')
    if (!phoneEl) return

    phoneEl.style.cursor = 'crosshair'

    function handleCapture(e: MouseEvent) {
      e.stopPropagation()
      e.preventDefault()
      const phoneRect = phoneEl!.getBoundingClientRect()
      const scale = phoneRect.width / phoneEl!.offsetWidth
      const lx = (e.clientX - phoneRect.left) / scale
      const ly = (e.clientY - phoneRect.top) / scale
      const hits = elementsRef.current.filter(el =>
        lx >= el.ox && lx <= el.ox + el.ow &&
        ly >= el.oy && ly <= el.oy + el.oh
      )
      // Pick the smallest element at that point (most specific); click again to deselect
      const best = hits.sort((a, b) => (a.ow * a.oh) - (b.ow * b.oh))[0]
      const current = focusedBlockIDRef.current
      setFocusedBlockID(best ? (current === best.id ? null : best.id) : null)
    }

    phoneEl.addEventListener('click', handleCapture, { capture: true })
    return () => {
      phoneEl.style.cursor = ''
      phoneEl.removeEventListener('click', handleCapture, { capture: true })
    }
  }, [showRedlines, setFocusedBlockID])

  if (!showRedlines || elements.length === 0) return null

  const focused = focusedBlockID ? elements.find(e => e.id === focusedBlockID) ?? null : null

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
      {/* Padding fills for focused element (drawn below everything) */}
      {focused && <PaddingFills el={focused} />}
      {focused && <GapFill el={focused} />}

      {/* Spacing annotations between adjacent named blocks */}
      {showSpacing && <SpacingAnnotations elements={elements} />}

      {/* Dimension lines for ALL named blocks — always on */}
      {elements.filter(el => el.isNamedBlock).map(el => (
        <DimensionLines key={el.id + '-dim'} el={el} />
      ))}
      {/* Dimension lines for focused non-named element */}
      {focused && !focused.isNamedBlock && (
        <DimensionLines el={focused} />
      )}

      {/* Outlines for all elements */}
      {elements.map(el => {
        const isFocused = el.id === focusedBlockID
        const dimmed = !!focusedBlockID && !isFocused
        return (
          <g key={el.id}>
            <rect
              x={el.x} y={el.y} width={el.w} height={el.h}
              fill="none"
              stroke={RL_STROKE}
              strokeWidth={isFocused ? 2 : el.isNamedBlock ? 1 : 0.75}
              strokeOpacity={dimmed ? 0.1 : isFocused ? 1 : el.isNamedBlock ? 0.75 : 0.45}
            />
            {/* Type label — named blocks always; non-named blocks in allDims mode */}
            {el.isNamedBlock && (
              <TypeLabel x={el.x + 4} y={el.y + 4} text={el.blockType} color={el.color} />
            )}
            {/* Size label — non-named visual elements when allDims is on */}
            {showAllDims && !el.isNamedBlock && !isFocused && (
              <SizeLabel el={el} />
            )}
          </g>
        )
      })}

    </svg>
  )
}
