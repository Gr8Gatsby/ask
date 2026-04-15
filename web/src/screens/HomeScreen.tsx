import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import type { Block, TilePayload, AgentSessionPayload, CountdownPayload, Urgency, QuickReplyPayload } from '../lib/types'
import { useBlocks } from '../lib/useBlocks'
import { useTheme } from '../lib/PlatformContext'
import { useSettings } from '../lib/SettingsContext'
import ScriptIcon from '../components/shared/ScriptIcon'
import UrgencyBadge from '../components/shared/UrgencyBadge'
import QuickReplyBlock from '../components/blocks/QuickReplyBlock'

// ---- helpers ----

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

const DOT: Record<string, string> = {
  green: 'bg-ask-green', blue: 'bg-ask-blue', orange: 'bg-ask-orange',
  red: 'bg-ask-red', yellow: 'bg-ask-yellow',
}

// Find the first agent_session block that has a pending_confirmation
function pendingAgentSession(blocks: Block[]): { block: Block; payload: AgentSessionPayload } | null {
  for (const b of blocks) {
    if (b.blockType !== 'agent_session') continue
    const p = parsePayload<AgentSessionPayload>(b.payload)
    if (p?.pending_confirmation) return { block: b, payload: p }
  }
  return null
}

function dominantUrgency(inboxBlocks: Block[], allBlocks?: Block[]): Urgency {
  // Agent sessions waiting for permission are always treated as urgent
  if (allBlocks && pendingAgentSession(allBlocks)) return 'urgent'
  const urgencies = inboxBlocks.map(b => parsePayload<{ urgency?: Urgency }>(b.payload)?.urgency)
  if (urgencies.includes('urgent')) return 'urgent'
  if (urgencies.includes('info'))   return 'info'
  return 'warning'
}

function tileStatus(blocks: Block[]): { color?: string; label?: string; body?: string } {
  const tile = parsePayload<TilePayload>(blocks.find(b => b.blockType === 'tile')?.payload ?? 'null')
  if (tile) return { color: tile.status_color, label: tile.label, body: tile.body }

  // Fall back to agent session info
  const sessions = blocks.filter(b => b.blockType === 'agent_session')
  if (sessions.length > 0) {
    const working = sessions.filter(b => parsePayload<AgentSessionPayload>(b.payload)?.is_working)
    const label = working.length > 0
      ? `${sessions.length} session${sessions.length > 1 ? 's' : ''}, ${working.length} working`
      : `${sessions.length} session${sessions.length > 1 ? 's' : ''}`
    const body = parsePayload<AgentSessionPayload>(sessions[0].payload)?.last_message?.split('\n')[0]?.slice(0, 120)
    return { color: working.length > 0 ? 'blue' : undefined, label, body }
  }
  return {}
}

// ---- Live countdown hook ----

function useCountdownDisplay(isoTime: string | undefined): string | null {
  const [display, setDisplay] = useState<string | null>(null)
  useEffect(() => {
    if (!isoTime) { setDisplay(null); return }
    const target = new Date(isoTime)
    function fmt() {
      const diff = target.getTime() - Date.now()
      if (diff <= 0) return 'overdue'
      const h = Math.floor(diff / 3_600_000)
      const m = Math.floor((diff % 3_600_000) / 60_000)
      const s = Math.floor((diff % 60_000) / 1_000)
      if (h > 48) return `in ${Math.floor(h / 24)}d`
      if (h > 0) return `${h}h ${m}m`
      if (m > 0) return `${m}m ${s}s`
      return `${s}s`
    }
    setDisplay(fmt())
    const interval = (target.getTime() - Date.now()) > 3_600_000 ? 30_000 : 1_000
    const id = setInterval(() => setDisplay(fmt()), interval)
    return () => clearInterval(id)
  }, [isoTime])
  return display
}

// ---- Action queue card (Needs Response) ----

function ActionQueueCard({ scriptID, blocks, onRespond }: { scriptID: string; blocks: Block[]; onRespond: (id: string, v: string) => void }) {
  const navigate = useNavigate()
  const theme = useTheme()
  const { useBrandColors } = useSettings()
  const first = blocks[0]
  const { color, label, body } = tileStatus(blocks)
  const inboxBlocks = blocks.filter(b => b.showsInInbox === 1)
  const urgency = dominantUrgency(inboxBlocks, blocks)

  const urgencyRank = (u?: Urgency) => u === 'urgent' ? 0 : u === 'info' ? 2 : 1
  const quickReplyBlock = inboxBlocks
    .filter(b => b.blockType === 'quick_reply')
    .sort((a, b) => {
      const ua = urgencyRank(parsePayload<{ urgency?: Urgency }>(a.payload)?.urgency)
      const ub = urgencyRank(parsePayload<{ urgency?: Urgency }>(b.payload)?.urgency)
      return ua !== ub ? ua - ub : new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
    })[0]

  // Agent session — used for pending_confirmation inline and for Feed/Stop actions
  const agentSession = blocks.find(b => b.blockType === 'agent_session')
  const agentPayload = agentSession ? parsePayload<AgentSessionPayload>(agentSession.payload) : null

  // Pending confirmation: prefer standalone quick_reply, then agent session pending
  const pendingSession = !quickReplyBlock ? pendingAgentSession(blocks) : null
  const pending = pendingSession?.payload.pending_confirmation

  // Destination when tapping the card header
  const cardTarget = agentPayload?.session_id
    ? `/script/${scriptID}/session/${agentPayload.session_id}`
    : `/script/${scriptID}`

  const hasInline = !!(quickReplyBlock || pending)
  const borderColor = urgency === 'urgent' ? 'border-ask-red/40' : urgency === 'info' ? 'border-ask-sep' : 'border-ask-orange/40'
  const cardClass = theme.isAndroid
    ? `bg-ask-card rounded-2xl shadow-md shadow-black/50 overflow-hidden`
    : `bg-ask-card rounded-xl border ${borderColor} overflow-hidden`
  const brandColor = useBrandColors ? (agentPayload?.brand_color ?? null) : null

  return (
    <div className={cardClass}>
      {/* Brand color accent strip */}
      {brandColor && (
        <div style={{ height: 3, backgroundColor: brandColor, opacity: 0.85 }} />
      )}
      {/* Header row */}
      <button
        onClick={() => navigate(cardTarget)}
        className="w-full flex items-center gap-3 px-3.5 py-3.5 hover:bg-ask-text/[0.05] transition-colors text-left"
      >
        <ScriptIcon
          scriptIconData={first.scriptIconData}
          scriptIconSVG={first.scriptIconSVG}
          scriptIcon={first.scriptIcon}
          scriptName={first.scriptName}
          size={36}
        />
        <div className="flex-1 min-w-0">
          <p className="text-[15px] font-semibold text-ask-text leading-tight truncate">{first.scriptName}</p>
          {label && (
            <div className="flex items-center gap-1.5 mt-0.5">
              {color && <span className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${DOT[color] ?? 'bg-ask-secondary'}`} />}
              <span className="text-xs text-ask-secondary truncate">{label}</span>
            </div>
          )}
          {body && !label && (
            <p className="text-xs text-ask-secondary truncate mt-0.5">{body}</p>
          )}
        </div>
        <div className="flex items-center gap-1.5 flex-shrink-0">
          <UrgencyBadge urgency={urgency} />
          {!hasInline && !agentSession && <span className="text-ask-secondary text-sm ml-1">›</span>}
        </div>
      </button>

      {/* Agent session action row — Feed, permission mode, Stop */}
      {agentSession && agentPayload && (
        <>
          <div className="h-px bg-ask-sep mx-3.5" />
          <div className="flex items-center gap-2 px-3.5 py-2">
            <div
              className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${agentPayload.is_working ? 'animate-pulse' : ''}`}
              style={{ backgroundColor: agentPayload.is_working ? (useBrandColors ? (agentPayload.brand_color ?? '#8E8E93') : '#8E8E93') : undefined }}
            />
            <span className="text-[11px] text-ask-secondary flex-1 truncate">
              {agentPayload.is_working
                ? (agentPayload.current_tool
                    ? `${agentPayload.current_tool}: ${agentPayload.current_preview ?? '…'}`
                    : 'Working…')
                : (agentPayload.last_message?.split('\n').find(l => l.trim())?.replace(/^#+\s*/, '').slice(0, 80) ?? 'Ready')}
            </span>
            {agentPayload.permission_mode && (
              <button
                onClick={() => onRespond(agentSession.blockID, '__permissions__')}
                className="text-[10px] px-1.5 py-0.5 rounded bg-ask-card2 text-ask-secondary hover:text-ask-text border border-ask-sep/50 transition-colors flex-shrink-0"
              >
                {agentPayload.permission_mode === 'full-auto' ? 'auto' : 'supervised'}
              </button>
            )}
            {agentPayload.task_id && (
              <button
                onClick={() => navigate(`/tasks/${agentPayload.task_id}`)}
                className="text-[11px] text-ask-blue font-medium flex-shrink-0"
              >
                Feed
              </button>
            )}
            <button
              onClick={() => onRespond(agentSession.blockID, '__close_session__')}
              className="text-[11px] text-ask-red font-medium border border-ask-red/30 px-2 py-0.5 rounded-lg hover:bg-ask-red/10 transition-colors flex-shrink-0"
            >
              Stop
            </button>
          </div>
        </>
      )}

      {quickReplyBlock && (
        <>
          <div className="h-px bg-ask-sep mx-3.5" />
          <div className="px-3.5 pt-3 pb-3.5">
            <QuickReplyBlock
              block={quickReplyBlock}
              payload={parsePayload<QuickReplyPayload>(quickReplyBlock.payload)!}
              onRespond={onRespond}
            />
          </div>
        </>
      )}

      {pending && pendingSession && (
        <>
          <div className="h-px bg-ask-sep mx-3.5" />
          <div className="px-3.5 pt-2.5 pb-3">
            <p className="text-xs font-semibold text-ask-text mb-1.5">{pending.title}</p>
            {pending.body && (
              <p className="text-[12px] font-mono text-ask-text mb-2.5 leading-snug bg-ask-card2 px-2.5 py-1.5 rounded-lg break-all border border-ask-sep/30">
                {pending.body}
              </p>
            )}
            <div className="flex flex-wrap gap-2">
              {pending.options.map(opt => {
                const lc = opt.toLowerCase()
                const isAlways = lc.startsWith('always')
                const isDeny = lc === 'deny' || lc === 'no' || lc.startsWith('deny')
                const label = isAlways ? 'Always' : isDeny ? 'Deny' : opt
                return (
                  <button
                    key={opt}
                    onClick={() => onRespond(pendingSession.block.blockID, opt)}
                    className={`px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors ${
                      isDeny
                        ? 'bg-ask-red/10 text-ask-red border border-ask-red/30'
                        : isAlways
                        ? 'bg-ask-orange/10 text-ask-orange border border-ask-orange/30'
                        : 'bg-ask-blue text-white'
                    }`}
                  >
                    {label}
                  </button>
                )
              })}
            </div>
          </div>
        </>
      )}
    </div>
  )
}

// ---- Script tile (Recent — full-width single column) ----

function ScriptTile({ scriptID, blocks }: { scriptID: string; blocks: Block[] }) {
  const navigate = useNavigate()
  const theme = useTheme()
  const first = blocks[0]
  const { color, label, body } = tileStatus(blocks)
  const tile = parsePayload<TilePayload>(blocks.find(b => b.blockType === 'tile')?.payload ?? 'null')
  const countdown = parsePayload<CountdownPayload>(blocks.find(b => b.blockType === 'countdown')?.payload ?? 'null')
  const isActionRequired = tile?.action_required
  const countdownDisplay = useCountdownDisplay(countdown?.time)

  const tileClass = theme.isAndroid
    ? `w-full flex items-center gap-3 bg-ask-card rounded-2xl px-3.5 py-3.5 shadow-md shadow-black/40 hover:bg-ask-card2 transition-colors text-left`
    : `w-full flex items-center gap-3 bg-ask-card rounded-xl px-3.5 py-3.5 border ${
        isActionRequired ? 'border-ask-orange/40' : 'border-ask-sep/50'
      } hover:bg-ask-card2 transition-colors text-left`

  return (
    <button
      onClick={() => navigate(`/script/${scriptID}`)}
      className={tileClass}
    >
      <ScriptIcon
        scriptIconData={first.scriptIconData}
        scriptIconSVG={first.scriptIconSVG}
        scriptIcon={first.scriptIcon}
        scriptName={first.scriptName}
        size={30}
      />
      <div className="flex-1 min-w-0">
        <p className="text-[15px] font-semibold text-ask-text leading-tight truncate">{first.scriptName}</p>
        {label && (
          <div className="flex items-center gap-1.5 mt-0.5">
            {color && <span className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${DOT[color] ?? 'bg-ask-secondary'}`} />}
            <span className="text-xs text-ask-secondary truncate">{label}</span>
          </div>
        )}
        {body && (
          <p className="text-xs text-ask-secondary/70 truncate mt-0.5">{body}</p>
        )}
      </div>
      <div className="flex items-center gap-2 flex-shrink-0">
        {countdownDisplay && (
          <span className="text-xs font-mono tabular-nums text-ask-orange">{countdownDisplay}</span>
        )}
        {isActionRequired && (
          <span className="text-ask-orange text-base">!</span>
        )}
      </div>
    </button>
  )
}

// ---- Screen ----

export default function HomeScreen() {
  const { scriptGroups, loading, error, respond } = useBlocks()
  const theme = useTheme()

  if (loading) {
    return <div className="flex items-center justify-center h-full text-ask-secondary text-sm">Connecting to MockAskMac…</div>
  }
  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full gap-3 p-6 text-center">
        <p className="text-ask-red font-semibold text-sm">MockAskMac not running</p>
        <p className="text-ask-secondary text-xs">Run <code className="font-mono bg-ask-card px-1.5 py-0.5 rounded">npm run dev</code> in ask/web/</p>
      </div>
    )
  }

  const entries = Object.entries(scriptGroups)
  const needsResponseGroups = entries
    .filter(([, blocks]) => blocks.some(b => b.showsInInbox === 1) || !!pendingAgentSession(blocks))
    .sort(([, a], [, b]) => {
      const ua = dominantUrgency(a.filter(b => b.showsInInbox === 1), a)
      const ub = dominantUrgency(b.filter(b => b.showsInInbox === 1), b)
      const rank = (u: Urgency) => u === 'urgent' ? 0 : u === 'warning' ? 1 : 2
      return rank(ua) - rank(ub)
    })
  const recentGroups = entries.filter(([, blocks]) =>
    !blocks.some(b => b.showsInInbox === 1) && !pendingAgentSession(blocks)
  )

  return (
    <div className="flex flex-col h-full">
      {/* Nav */}
      {theme.isAndroid ? (
        <div className="flex items-center justify-between px-4 pt-4 pb-3 flex-shrink-0">
          <h1 className="text-[28px] font-medium text-ask-text leading-tight">Ask</h1>
          <span className="text-xs text-ask-secondary">MockAskMac</span>
        </div>
      ) : (
        <div className="flex items-center justify-between px-4 pt-3 pb-2 flex-shrink-0">
          <h1 className="text-[34px] font-bold text-ask-text leading-tight">Ask</h1>
          <span className="text-xs text-ask-secondary">MockAskMac</span>
        </div>
      )}

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto no-scrollbar px-4 pb-4 flex flex-col gap-5">
        {needsResponseGroups.length > 0 && (
          <section className="flex flex-col gap-2">
            <div className="flex items-center gap-2">
              <p className="text-xs font-semibold text-ask-secondary uppercase tracking-wide">Needs Response</p>
              <span className="text-[10px] font-bold bg-ask-orange/20 text-ask-orange px-1.5 py-0.5 rounded-full">
                {needsResponseGroups.length}
              </span>
            </div>
            {needsResponseGroups.map(([scriptID, blocks]) => (
              <ActionQueueCard key={scriptID} scriptID={scriptID} blocks={blocks} onRespond={respond} />
            ))}
          </section>
        )}

        {recentGroups.length > 0 && (
          <section className="flex flex-col gap-2">
            {needsResponseGroups.length > 0 && (
              <p className="text-xs font-semibold text-ask-secondary uppercase tracking-wide">Recent</p>
            )}
            {recentGroups.map(([scriptID, blocks]) => (
              <ScriptTile key={scriptID} scriptID={scriptID} blocks={blocks} />
            ))}
          </section>
        )}

        {entries.length === 0 && (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No active scripts</div>
        )}
      </div>

    </div>
  )
}
