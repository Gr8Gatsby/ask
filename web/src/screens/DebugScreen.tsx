import { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import { subscribeDebug, clearDebug, logDebug, type DebugEntry } from '../lib/debugLog'
import { subscribeToDebugEvents } from '../lib/api'
import { usePlatform } from '../lib/PlatformContext'
import { IOSStatusBarRow, iosNavChromeStyle } from '../components/layout/AppShell'
import type { AgentSessionPayload } from '../lib/types'

type Tab = 'events' | 'blocks' | 'sessions'

// ---- helpers ----

function fmt(ts: number): string {
  const d = new Date(ts)
  const hh = d.getHours().toString().padStart(2, '0')
  const mm = d.getMinutes().toString().padStart(2, '0')
  const ss = d.getSeconds().toString().padStart(2, '0')
  const ms = d.getMilliseconds().toString().padStart(3, '0')
  return `${hh}:${mm}:${ss}.${ms}`
}

function tryParse(json: string): unknown {
  try { return JSON.parse(json) } catch { return json }
}

// ---- Event row ----

const DIR_COLOR: Record<string, string> = {
  '←': 'text-ask-green',
  '→': 'text-ask-blue',
  '↕': 'text-ask-orange',
}

const CAT_BG: Record<string, string> = {
  SSE:     'bg-ask-green/15 text-ask-green',
  RESPOND: 'bg-ask-blue/15 text-ask-blue',
  SERVER:  'bg-ask-orange/15 text-ask-orange',
  CONN:    'bg-ask-secondary/15 text-ask-secondary',
}

function EventRow({ entry }: { entry: DebugEntry }) {
  const [open, setOpen] = useState(false)
  const hasDetail = !!entry.detail
  return (
    <div
      className={`border-b border-ask-sep/30 ${entry.error ? 'bg-ask-red/5' : ''}`}
      onClick={() => hasDetail && setOpen(v => !v)}
    >
      <div className={`flex items-start gap-2 px-3 py-2 ${hasDetail ? 'cursor-pointer active:bg-ask-sep/10' : ''}`}>
        <span className="font-mono text-[10px] text-ask-secondary/60 flex-shrink-0 mt-px w-[82px]">
          {fmt(entry.ts)}
        </span>
        <span className={`font-mono text-[12px] font-bold flex-shrink-0 w-3 mt-px ${DIR_COLOR[entry.dir] ?? 'text-ask-secondary'}`}>
          {entry.dir}
        </span>
        <span className={`text-[10px] font-mono px-1 py-0.5 rounded flex-shrink-0 ${CAT_BG[entry.category] ?? ''}`}>
          {entry.category}
        </span>
        <div className="flex-1 min-w-0">
          <p className={`text-[12px] font-mono leading-snug ${entry.error ? 'text-ask-red' : 'text-ask-text'}`}>
            {entry.label}
          </p>
          {entry.detail && !open && (
            <p className="text-[10px] font-mono text-ask-secondary/70 truncate">{entry.detail}</p>
          )}
        </div>
        {hasDetail && (
          <span className="text-ask-secondary/40 text-[10px] flex-shrink-0 mt-px">{open ? '▲' : '▼'}</span>
        )}
      </div>
      {open && entry.detail && (
        <div className="px-3 pb-2 ml-[97px]">
          <pre className="text-[10px] font-mono text-ask-secondary bg-ask-card2/60 rounded px-2 py-1.5 overflow-x-auto whitespace-pre-wrap break-all">
            {entry.detail}
          </pre>
        </div>
      )}
    </div>
  )
}

// ---- Blocks tab ----

function BlocksTab() {
  const { blocks } = useBlocks()
  const [expanded, setExpanded] = useState<Set<string>>(new Set())

  const toggle = (id: string) => setExpanded(prev => {
    const next = new Set(prev)
    if (next.has(id)) next.delete(id); else next.add(id)
    return next
  })

  const grouped = blocks.reduce<Record<string, typeof blocks>>((acc, b) => {
    if (!acc[b.scriptID]) acc[b.scriptID] = []
    acc[b.scriptID].push(b)
    return acc
  }, {})

  return (
    <div className="flex flex-col">
      <div className="px-3 py-2 border-b border-ask-sep/30">
        <p className="text-[11px] text-ask-secondary font-mono">{blocks.length} block{blocks.length !== 1 ? 's' : ''} total</p>
      </div>
      {Object.entries(grouped).map(([scriptID, sBlocks]) => (
        <div key={scriptID}>
          <div className="px-3 py-1.5 bg-ask-card2/40 border-b border-ask-sep/30">
            <p className="text-[11px] font-semibold font-mono text-ask-secondary">{scriptID}</p>
          </div>
          {sBlocks.map(b => (
            <div key={b.blockID} className="border-b border-ask-sep/20">
              <button
                className="w-full flex items-start gap-2 px-3 py-2 text-left active:bg-ask-sep/10"
                onClick={() => toggle(b.blockID)}
              >
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-1.5 flex-wrap">
                    <span className="text-[11px] font-mono text-ask-text">{b.blockID}</span>
                    <span className="text-[10px] font-mono px-1 py-0.5 rounded bg-ask-secondary/10 text-ask-secondary">{b.blockType}</span>
                    {b.showsInInbox === 1 && (
                      <span className="text-[10px] font-mono px-1 py-0.5 rounded bg-ask-orange/15 text-ask-orange">inbox</span>
                    )}
                    {b.requiresResponse === 1 && (
                      <span className="text-[10px] font-mono px-1 py-0.5 rounded bg-ask-red/15 text-ask-red">response</span>
                    )}
                  </div>
                </div>
                <span className="text-ask-secondary/40 text-[10px] flex-shrink-0 mt-0.5">{expanded.has(b.blockID) ? '▲' : '▼'}</span>
              </button>
              {expanded.has(b.blockID) && (
                <div className="px-3 pb-2">
                  <pre className="text-[10px] font-mono text-ask-secondary bg-ask-card2/60 rounded px-2 py-1.5 overflow-x-auto whitespace-pre-wrap break-all">
                    {JSON.stringify(tryParse(b.payload), null, 2)}
                  </pre>
                </div>
              )}
            </div>
          ))}
        </div>
      ))}
      {blocks.length === 0 && (
        <p className="text-[12px] text-ask-secondary font-mono text-center py-8">No blocks</p>
      )}
    </div>
  )
}

// ---- Sessions tab ----

function SessionsTab() {
  const { blocks } = useBlocks()
  const sessions = blocks.filter(b => b.blockType === 'agent_session')

  return (
    <div className="flex flex-col">
      <div className="px-3 py-2 border-b border-ask-sep/30">
        <p className="text-[11px] text-ask-secondary font-mono">{sessions.length} session block{sessions.length !== 1 ? 's' : ''}</p>
      </div>
      {sessions.map(b => {
        let p: AgentSessionPayload | null = null
        try { p = JSON.parse(b.payload) as AgentSessionPayload } catch { /* ignore */ }
        return (
          <div key={b.blockID} className="border-b border-ask-sep/30 px-3 py-3">
            <div className="flex items-center gap-2 mb-1.5">
              <div className={`w-2 h-2 rounded-full flex-shrink-0 ${p?.is_working ? 'bg-ask-blue animate-pulse' : 'bg-ask-secondary/40'}`} />
              <span className="text-[13px] font-semibold text-ask-text">{p?.project ?? b.scriptID}</span>
              <span className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-ask-secondary/10 text-ask-secondary">
                {p?.is_working ? 'working' : 'idle'}
              </span>
              {p?.permission_mode && (
                <span className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-ask-orange/15 text-ask-orange">
                  {p.permission_mode}
                </span>
              )}
            </div>
            <div className="ml-4 flex flex-col gap-0.5">
              <p className="text-[10px] font-mono text-ask-secondary">
                <span className="text-ask-secondary/50">block </span>{b.blockID}
              </p>
              {p?.session_id && (
                <p className="text-[10px] font-mono text-ask-secondary">
                  <span className="text-ask-secondary/50">session </span>{p.session_id}
                </p>
              )}
              {p?.current_tool && (
                <p className="text-[10px] font-mono text-ask-blue">
                  {p.current_tool}{p.current_preview ? `: ${p.current_preview.slice(0, 60)}` : ''}
                </p>
              )}
              {p?.last_message && (
                <p className="text-[10px] font-mono text-ask-secondary/70 truncate">
                  {p.last_message.split('\n').find(l => l.trim())?.slice(0, 120)}
                </p>
              )}
            </div>
          </div>
        )
      })}
      {sessions.length === 0 && (
        <p className="text-[12px] text-ask-secondary font-mono text-center py-8">No active sessions</p>
      )}
    </div>
  )
}

// ---- Screen ----

export default function DebugScreen() {
  const navigate = useNavigate()
  const { themeMode } = usePlatform()
  const isLight = themeMode === 'light'
  const [tab, setTab] = useState<Tab>('events')
  const [entries, setEntries] = useState<DebugEntry[]>([])
  const [serverConnected, setServerConnected] = useState<boolean | null>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const [autoScroll, setAutoScroll] = useState(true)

  useEffect(() => subscribeDebug(setEntries), [])

  // Try to subscribe to mock server debug SSE; graceful if unavailable
  useEffect(() => {
    let unsub: (() => void) | null = null
    let connected = false
    try {
      unsub = subscribeToDebugEvents((event) => {
        if (!connected) { connected = true; setServerConnected(true) }
        const { type } = event
        const d = event.data as Record<string, string>
        if (type === 'respond_received') {
          logDebug({
            dir: '↕', category: 'SERVER',
            label: `server received respond ${d.blockID} (${d.scriptID || 'no route'})`,
            detail: `value: ${d.value}`,
          })
        } else if (type === 'socket_sent') {
          logDebug({
            dir: '↕', category: 'SERVER',
            label: `socket → ${d.scriptID} (session=${d.sessionID})`,
            detail: `value: ${d.value}`,
          })
        } else if (type === 'socket_error') {
          logDebug({ dir: '↕', category: 'SERVER', label: `socket error → ${d.scriptID}`, detail: d.error, error: true })
        } else if (type === 'snapshot_reload') {
          logDebug({ dir: '↕', category: 'SERVER', label: `snapshot reloaded (${d.blockCount} blocks)` })
        }
      })
    } catch {
      setServerConnected(false)
    }

    const timeout = setTimeout(() => {
      if (!connected) setServerConnected(false)
    }, 3000)

    return () => { unsub?.(); clearTimeout(timeout) }
  }, [])

  useEffect(() => {
    if (autoScroll && listRef.current && tab === 'events') {
      listRef.current.scrollTop = 0
    }
  }, [entries, autoScroll, tab])

  const TABS: { key: Tab; label: string }[] = [
    { key: 'events', label: 'Events' },
    { key: 'blocks', label: 'Blocks' },
    { key: 'sessions', label: 'Sessions' },
  ]

  return (
    <div className="relative h-full bg-ask-bg flex flex-col">
      <div className="flex-shrink-0 z-20" style={iosNavChromeStyle(isLight)}>
        <IOSStatusBarRow />
        <div className="flex items-center px-4 pb-2 gap-2">
          <button
            onClick={() => navigate('/settings')}
            className="flex items-center gap-1 text-ask-blue text-[17px] py-1 pr-2"
          >
            <svg width="8" height="13" viewBox="0 0 8 13" fill="none">
              <path d="M7 1L1 6.5L7 12" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
            Settings
          </button>
          <p className="flex-1 text-center text-[17px] font-semibold text-ask-text -ml-16">Debug Console</p>
          {tab === 'events' && (
            <button onClick={clearDebug} className="text-ask-blue text-[15px]">Clear</button>
          )}
        </div>

        <div className="flex border-b border-ask-sep/40">
          {TABS.map(t => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`flex-1 py-2 text-[13px] font-medium transition-colors ${
                tab === t.key
                  ? 'text-ask-blue border-b-2 border-ask-blue -mb-px'
                  : 'text-ask-secondary'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      <div
        ref={listRef}
        className="flex-1 overflow-y-auto no-scrollbar"
        onScroll={() => {
          if (listRef.current && tab === 'events') {
            setAutoScroll(listRef.current.scrollTop < 20)
          }
        }}
      >
        {tab === 'events' && (
          <div>
            {serverConnected === false && (
              <div className="px-3 py-2 bg-ask-orange/10 border-b border-ask-orange/20">
                <p className="text-[11px] font-mono text-ask-orange">
                  Server events unavailable — not connected to mock server
                </p>
              </div>
            )}
            {serverConnected === true && (
              <div className="px-3 py-2 bg-ask-green/10 border-b border-ask-green/20">
                <p className="text-[11px] font-mono text-ask-green">Mock server events connected</p>
              </div>
            )}
            {entries.length === 0 && (
              <p className="text-[12px] text-ask-secondary font-mono text-center py-8">
                No events yet — interact with the app
              </p>
            )}
            {entries.map(e => <EventRow key={e.id} entry={e} />)}
          </div>
        )}
        {tab === 'blocks' && <BlocksTab />}
        {tab === 'sessions' && <SessionsTab />}
      </div>

      {tab === 'events' && !autoScroll && entries.length > 0 && (
        <button
          onClick={() => { setAutoScroll(true); listRef.current?.scrollTo({ top: 0, behavior: 'smooth' }) }}
          className="absolute bottom-4 right-4 bg-ask-blue text-white text-[12px] font-medium px-3 py-1.5 rounded-full shadow-lg"
        >
          ↑ Latest
        </button>
      )}
    </div>
  )
}
