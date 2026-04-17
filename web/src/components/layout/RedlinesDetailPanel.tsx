import { useEffect, useState } from 'react'
import { useRedlines } from '../../lib/RedlinesContext'

// ---- Option toggle ----

function OptionToggle({ active, onChange, label, color }: {
  active: boolean; onChange: (v: boolean) => void; label: string; color: string
}) {
  return (
    <button
      onClick={() => onChange(!active)}
      style={{
        flex: 1,
        fontSize: 11, fontWeight: 600, padding: '4px 8px',
        borderRadius: 6, cursor: 'pointer', transition: 'all 0.15s',
        background: active ? `${color}18` : 'rgba(0,0,0,0.04)',
        color: active ? color : 'rgba(0,0,0,0.38)',
        border: `1px solid ${active ? color + '50' : 'rgba(0,0,0,0.08)'}`,
        textAlign: 'center' as const,
      }}
    >
      {label}
    </button>
  )
}

// ---- DOM element lookup ----

function findElement(id: string): HTMLElement | null {
  const phoneEl = document.getElementById('phone-screen')
  if (!phoneEl || !id) return null
  // domKey format: "el-N.N.N" → traverse child indices
  if (id.startsWith('el-')) {
    const parts = id.slice(3).split('.').map(Number)
    let node: Element = phoneEl
    for (const idx of parts) {
      if (!node.children[idx]) return null
      node = node.children[idx]
    }
    return node as HTMLElement
  }
  // Named block: try data-block-id then data-script-id
  return (phoneEl.querySelector(`[data-block-id="${id}"]`) as HTMLElement | null)
      ?? (phoneEl.querySelector(`[data-script-id="${id}"]`) as HTMLElement | null)
}

// ---- Detail model ----

interface ElementDetail {
  tag: string
  blockType: string | null
  // Position + size in logical px
  x: number; y: number; w: number; h: number
  // Box model
  mt: number; mr: number; mb: number; ml: number
  pt: number; pr: number; pb: number; pl: number
  bt: number; br: number; bb: number; bl: number
  // Computed CSS
  backgroundColor: string
  borderRadius: string
  fontSize: string
  fontWeight: string
  color: string
  display: string
  flexDirection: string
  gap: string
}

function measureElement(id: string): ElementDetail | null {
  const el = findElement(id)
  if (!el) return null
  const phoneEl = document.getElementById('phone-screen')!
  const phoneRect = phoneEl.getBoundingClientRect()
  const scale = phoneRect.width / phoneEl.offsetWidth
  const rect = el.getBoundingClientRect()
  const cs = getComputedStyle(el)
  const p = (v: string) => Math.round(parseFloat(v) || 0)

  return {
    tag: el.tagName.toLowerCase(),
    blockType: el.getAttribute('data-block-type'),
    x: Math.round((rect.left - phoneRect.left) / scale),
    y: Math.round((rect.top - phoneRect.top) / scale),
    w: Math.round(rect.width / scale),
    h: Math.round(rect.height / scale),
    mt: p(cs.marginTop), mr: p(cs.marginRight),
    mb: p(cs.marginBottom), ml: p(cs.marginLeft),
    pt: p(cs.paddingTop), pr: p(cs.paddingRight),
    pb: p(cs.paddingBottom), pl: p(cs.paddingLeft),
    bt: p(cs.borderTopWidth), br: p(cs.borderRightWidth),
    bb: p(cs.borderBottomWidth), bl: p(cs.borderLeftWidth),
    backgroundColor: cs.backgroundColor,
    borderRadius: cs.borderRadius,
    fontSize: cs.fontSize,
    fontWeight: cs.fontWeight,
    color: cs.color,
    display: cs.display,
    flexDirection: cs.flexDirection,
    gap: cs.gap === 'normal' ? '' : cs.gap,
  }
}

// ---- Sub-components ----

function Row({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false)
  function copy() {
    navigator.clipboard.writeText(value).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 400)
  }
  return (
    <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', padding: '3px 0' }}>
      <span style={{ fontSize: 11, color: 'rgba(0,0,0,0.4)', fontFamily: 'ui-monospace, monospace', flexShrink: 0 }}>
        {label}
      </span>
      <button
        onClick={copy}
        style={{
          fontSize: 12, fontFamily: 'ui-monospace, monospace', fontWeight: 500,
          color: copied ? 'rgb(52,199,89)' : 'rgba(0,0,0,0.82)',
          background: 'none', border: 'none', cursor: 'pointer',
          padding: '1px 4px', borderRadius: 3, maxWidth: 160,
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}
        title={value}
      >
        {value}
      </button>
    </div>
  )
}

function ColorRow({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false)
  function copy() {
    navigator.clipboard.writeText(value).catch(() => {})
    setCopied(true)
    setTimeout(() => setCopied(false), 400)
  }
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 5, padding: '3px 0' }}>
      <span style={{ fontSize: 11, color: 'rgba(0,0,0,0.4)', fontFamily: 'ui-monospace, monospace', flexShrink: 0 }}>
        {label}
      </span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 5, minWidth: 0 }}>
        <div style={{ width: 13, height: 13, borderRadius: 3, background: value, border: '1px solid rgba(0,0,0,0.12)', flexShrink: 0 }} />
        <button
          onClick={copy}
          style={{
            fontSize: 12, fontFamily: 'ui-monospace, monospace', fontWeight: 500,
            color: copied ? 'rgb(52,199,89)' : 'rgba(0,0,0,0.82)',
            background: 'none', border: 'none', cursor: 'pointer',
            overflow: 'hidden', textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
          }}
          title={value}
        >
          {value}
        </button>
      </div>
    </div>
  )
}

/** CSS DevTools-style box model diagram */
function BoxModelDiagram({ d }: { d: ElementDetail }) {
  const S = { fontSize: 8, fontFamily: 'ui-monospace, monospace' } as const

  // Edge values → "T R B L" or single value if uniform
  function edges(t: number, r: number, b: number, l: number) {
    if (t === r && r === b && b === l) return t === 0 ? '-' : String(t)
    return `${t} ${r} ${b} ${l}`
  }

  const marginStr  = edges(d.mt, d.mr, d.mb, d.ml)
  const borderStr  = edges(d.bt, d.br, d.bb, d.bl)
  const paddingStr = edges(d.pt, d.pr, d.pb, d.pl)

  const boxW = 200, boxH = 140
  // Layer insets
  const M = 14   // margin layer thickness
  const B = 10   // border layer thickness
  const P = 10   // padding layer thickness

  // Rects
  const mR = { x: 0,       y: 0,       w: boxW,           h: boxH }
  const bR = { x: M,       y: M,       w: boxW - 2*M,     h: boxH - 2*M }
  const pR = { x: M+B,     y: M+B,     w: boxW - 2*(M+B), h: boxH - 2*(M+B) }
  const cR = { x: M+B+P,   y: M+B+P,   w: boxW - 2*(M+B+P), h: boxH - 2*(M+B+P) }

  return (
    <svg width={boxW} height={boxH} viewBox={`0 0 ${boxW} ${boxH}`}
      style={{ display: 'block', margin: '4px auto 0' }}>
      {/* Margin — orange/yellow */}
      <rect x={mR.x} y={mR.y} width={mR.w} height={mR.h} fill="rgba(246,178,107,0.35)" stroke="rgba(246,178,107,0.6)" strokeWidth={0.5} />
      {/* Border — orange */}
      <rect x={bR.x} y={bR.y} width={bR.w} height={bR.h} fill="rgba(230,143,51,0.4)" stroke="rgba(230,143,51,0.6)" strokeWidth={0.5} />
      {/* Padding — green */}
      <rect x={pR.x} y={pR.y} width={pR.w} height={pR.h} fill="rgba(147,196,125,0.4)" stroke="rgba(147,196,125,0.6)" strokeWidth={0.5} />
      {/* Content — blue */}
      <rect x={cR.x} y={cR.y} width={cR.w} height={cR.h} fill="rgba(134,188,255,0.45)" stroke="rgba(100,160,240,0.6)" strokeWidth={0.5} />

      {/* Margin label */}
      <text x={3} y={10} fill="rgba(0,0,0,0.45)" {...S}>margin</text>
      <text x={boxW/2} y={10} textAnchor="middle" fill="rgba(0,0,0,0.6)" {...S}>{marginStr}</text>

      {/* Border label */}
      <text x={M+2} y={M+9} fill="rgba(0,0,0,0.45)" {...S}>border</text>
      <text x={boxW/2} y={M+9} textAnchor="middle" fill="rgba(0,0,0,0.65)" {...S}>{borderStr}</text>

      {/* Padding label */}
      <text x={M+B+2} y={M+B+9} fill="rgba(0,0,0,0.45)" {...S}>padding</text>
      <text x={boxW/2} y={M+B+9} textAnchor="middle" fill="rgba(0,0,0,0.65)" {...S}>{paddingStr}</text>

      {/* Content w × h */}
      <text x={boxW/2} y={boxH/2} textAnchor="middle" dominantBaseline="middle"
        fill="rgba(0,0,0,0.8)" fontSize={10} fontWeight={600}
        fontFamily="ui-monospace, monospace">
        {d.w} × {d.h}
      </text>
    </svg>
  )
}

// ---- Panel ----

const PANEL_SECTION: React.CSSProperties = {
  padding: '10px 14px',
  borderBottom: '1px solid rgba(0,0,0,0.07)',
}
const SECTION_TITLE: React.CSSProperties = {
  fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.35)',
  letterSpacing: 0.8, textTransform: 'uppercase',
  marginBottom: 8,
}

export default function RedlinesDetailPanel() {
  const { focusedBlockID, setFocusedBlockID, showAllDims, setShowAllDims, showSpacing, setShowSpacing } = useRedlines()
  const [detail, setDetail] = useState<ElementDetail | null>(null)

  useEffect(() => {
    if (!focusedBlockID) { setDetail(null); return }
    const t = setTimeout(() => setDetail(measureElement(focusedBlockID)), 30)
    return () => clearTimeout(t)
  }, [focusedBlockID])

  const title = detail ? (detail.blockType ?? detail.tag) : null
  const hasMargin   = detail ? detail.mt > 0 || detail.mr > 0 || detail.mb > 0 || detail.ml > 0 : false
  const hasBorder   = detail ? detail.bt > 0 || detail.br > 0 || detail.bb > 0 || detail.bl > 0 : false
  const hasBg       = detail ? detail.backgroundColor !== 'rgba(0, 0, 0, 0)' && detail.backgroundColor !== 'transparent' : false
  const hasRadius   = detail ? !!detail.borderRadius && detail.borderRadius !== '0px' : false
  const hasLayout   = detail ? detail.display !== 'block' && detail.display !== 'inline' : false

  return (
    <div style={{
      width: 320,
      maxHeight: 'calc(100vh - 120px)',
      overflowY: 'auto',
      flexShrink: 0,
      alignSelf: 'flex-start',
      background: 'rgba(255,255,255,0.92)',
      backdropFilter: 'blur(16px)',
      WebkitBackdropFilter: 'blur(16px)',
      borderRadius: 14,
      border: '1px solid rgba(0,0,0,0.10)',
      boxShadow: '0 4px 20px rgba(0,0,0,0.08)',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
      scrollbarWidth: 'none',
    }}>
      {/* Header */}
      <div style={{ padding: '10px 14px 8px', borderBottom: '1px solid rgba(0,0,0,0.07)', background: 'rgba(0,0,0,0.02)' }}>
        <span style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.35)', letterSpacing: 0.8, textTransform: 'uppercase' }}>
          Redlines
        </span>
      </div>

      {/* Options */}
      <div style={{ ...PANEL_SECTION, borderBottom: detail ? '1px solid rgba(0,0,0,0.07)' : 'none' }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <OptionToggle active={showAllDims} onChange={setShowAllDims} label="All elements" color="rgb(255,45,85)" />
          <OptionToggle active={showSpacing} onChange={setShowSpacing} label="Spacing" color="rgb(0,122,255)" />
        </div>
        {!detail && (
          <p style={{ margin: '8px 0 0', fontSize: 10, color: 'rgba(0,0,0,0.3)', lineHeight: 1.4 }}>
            Click any element to inspect it.
          </p>
        )}
      </div>

      {/* Element detail — only when something is focused */}
      {detail && (
        <>
          {/* Element header */}
          <div style={{ padding: '10px 14px 8px', borderBottom: '1px solid rgba(0,0,0,0.07)' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 4 }}>
              <span style={{ fontSize: 10, fontWeight: 700, color: 'rgba(0,0,0,0.35)', letterSpacing: 0.8, textTransform: 'uppercase' }}>
                Element
              </span>
              <button
                onClick={() => setFocusedBlockID(null)}
                style={{ fontSize: 14, lineHeight: 1, color: 'rgba(0,0,0,0.3)', background: 'none', border: 'none', cursor: 'pointer', padding: '0 2px' }}
              >
                ×
              </button>
            </div>
            <div style={{ fontSize: 16, fontWeight: 700, color: 'rgba(0,0,0,0.85)', marginBottom: 2 }}>{title}</div>
            <div style={{ fontSize: 11, color: 'rgba(0,0,0,0.35)', fontFamily: 'ui-monospace, monospace' }}>
              {'<'}{detail.tag}{'>'}
            </div>
          </div>

          {/* Dimensions */}
          <div style={PANEL_SECTION}>
            <div style={SECTION_TITLE}>Dimensions</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr' }}>
              <Row label="x" value={`${detail.x}px`} />
              <Row label="y" value={`${detail.y}px`} />
              <Row label="w" value={`${detail.w}px`} />
              <Row label="h" value={`${detail.h}px`} />
            </div>
          </div>

          {/* Box Model */}
          <div style={PANEL_SECTION}>
            <div style={SECTION_TITLE}>Box Model</div>
            <BoxModelDiagram d={detail} />
            <div style={{ marginTop: 10 }}>
              {hasMargin && (
                <Row label="margin" value={`${detail.mt} ${detail.mr} ${detail.mb} ${detail.ml}`} />
              )}
              {detail.pt > 0 && <Row label="padding-top" value={`${detail.pt}px`} />}
              {detail.pr > 0 && <Row label="padding-right" value={`${detail.pr}px`} />}
              {detail.pb > 0 && <Row label="padding-bottom" value={`${detail.pb}px`} />}
              {detail.pl > 0 && <Row label="padding-left" value={`${detail.pl}px`} />}
              {hasBorder && (
                <Row label="border" value={`${detail.bt} ${detail.br} ${detail.bb} ${detail.bl}`} />
              )}
            </div>
          </div>

          {/* Computed */}
          <div style={{ ...PANEL_SECTION, borderBottom: 'none' }}>
            <div style={SECTION_TITLE}>Computed</div>
            {hasLayout && <Row label="display" value={detail.display} />}
            {detail.flexDirection && detail.flexDirection !== 'row' && (
              <Row label="flex-dir" value={detail.flexDirection} />
            )}
            {detail.gap && <Row label="gap" value={detail.gap} />}
            {hasBg && <ColorRow label="background" value={detail.backgroundColor} />}
            {hasRadius && <Row label="border-radius" value={detail.borderRadius} />}
            <Row label="font-size" value={detail.fontSize} />
            <Row label="font-weight" value={detail.fontWeight} />
            <ColorRow label="color" value={detail.color} />
          </div>
        </>
      )}
    </div>
  )
}
