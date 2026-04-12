import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import type { Block, TilePayload, AgentSessionPayload, CountdownPayload, Urgency, QuickReplyPayload } from '../lib/types'
import { useBlocks } from '../lib/useBlocks'
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

function dominantUrgency(inboxBlocks: Block[]): Urgency {
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

// ---- Alert chip (one per needs-response script) ----

function AlertChip({ scriptID, blocks, onClick }: { scriptID: string; blocks: Block[]; onClick: () => void }) {
  const inboxBlocks = blocks.filter(b => b.showsInInbox === 1)
  const urgency = dominantUrgency(inboxBlocks)
  const first = blocks[0]

  const chipColor = urgency === 'urgent'
    ? 'bg-ask-red text-white'
    : urgency === 'info'
    ? 'bg-ask-blue text-white'
    : 'bg-ask-orange text-white'

  return (
    <button
      key={scriptID}
      onClick={onClick}
      className={`flex items-center gap-1.5 px-3 py-1.5 rounded-full flex-shrink-0 ${chipColor}`}
    >
      <span className="w-1.5 h-1.5 rounded-full bg-white/70 flex-shrink-0" />
      <span className="text-[11px] font-semibold whitespace-nowrap">{first.scriptName}</span>
      {inboxBlocks.length > 1 && (
        <span className="text-[10px] font-bold bg-white/25 rounded-full w-4 h-4 flex items-center justify-center">
          {inboxBlocks.length}
        </span>
      )}
    </button>
  )
}

// ---- Action queue card (Needs Response) ----

function ActionQueueCard({ scriptID, blocks, onRespond }: { scriptID: string; blocks: Block[]; onRespond: (id: string, v: string) => void }) {
  const navigate = useNavigate()
  const first = blocks[0]
  const { color, label, body } = tileStatus(blocks)
  const inboxBlocks = blocks.filter(b => b.showsInInbox === 1)
  const urgency = dominantUrgency(inboxBlocks)

  const urgencyRank = (u?: Urgency) => u === 'urgent' ? 0 : u === 'info' ? 2 : 1
  const quickReplyBlock = inboxBlocks
    .filter(b => b.blockType === 'quick_reply')
    .sort((a, b) => {
      const ua = urgencyRank(parsePayload<{ urgency?: Urgency }>(a.payload)?.urgency)
      const ub = urgencyRank(parsePayload<{ urgency?: Urgency }>(b.payload)?.urgency)
      return ua !== ub ? ua - ub : new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
    })[0]

  const borderColor = urgency === 'urgent' ? 'border-ask-red/40' : urgency === 'info' ? 'border-ask-sep' : 'border-ask-orange/40'

  return (
    <div className={`bg-ask-card rounded-xl border ${borderColor} overflow-hidden`}>
      <button
        onClick={() => navigate(`/script/${scriptID}`)}
        className="w-full flex items-center gap-3 px-3.5 py-3.5 hover:bg-white/5 transition-colors text-left"
      >
        <ScriptIcon
          scriptIconData={first.scriptIconData}
          scriptIconSVG={first.scriptIconSVG}
          scriptIcon={first.scriptIcon}
          scriptName={first.scriptName}
          size={30}
        />
        <div className="flex-1 min-w-0">
          <p className="text-[15px] font-semibold text-white leading-tight truncate">{first.scriptName}</p>
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
        <UrgencyBadge urgency={urgency} />
        {!quickReplyBlock && <span className="text-ask-secondary text-sm ml-1">›</span>}
      </button>

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
    </div>
  )
}

// ---- Script tile (Recent — full-width single column) ----

function ScriptTile({ scriptID, blocks }: { scriptID: string; blocks: Block[] }) {
  const navigate = useNavigate()
  const first = blocks[0]
  const { color, label, body } = tileStatus(blocks)
  const tile = parsePayload<TilePayload>(blocks.find(b => b.blockType === 'tile')?.payload ?? 'null')
  const countdown = parsePayload<CountdownPayload>(blocks.find(b => b.blockType === 'countdown')?.payload ?? 'null')
  const isActionRequired = tile?.action_required
  const countdownDisplay = useCountdownDisplay(countdown?.time)

  return (
    <button
      onClick={() => navigate(`/script/${scriptID}`)}
      className={`w-full flex items-center gap-3 bg-ask-card rounded-xl px-3.5 py-3.5 border ${
        isActionRequired ? 'border-ask-orange/40' : 'border-ask-sep/50'
      } hover:bg-ask-card2 transition-colors text-left`}
    >
      <ScriptIcon
        scriptIconData={first.scriptIconData}
        scriptIconSVG={first.scriptIconSVG}
        scriptIcon={first.scriptIcon}
        scriptName={first.scriptName}
        size={30}
      />
      <div className="flex-1 min-w-0">
        <p className="text-[15px] font-semibold text-white leading-tight truncate">{first.scriptName}</p>
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
  const navigate = useNavigate()

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
    .filter(([, blocks]) => blocks.some(b => b.showsInInbox === 1))
    .sort(([, a], [, b]) => {
      const ua = dominantUrgency(a.filter(b => b.showsInInbox === 1))
      const ub = dominantUrgency(b.filter(b => b.showsInInbox === 1))
      const rank = (u: Urgency) => u === 'urgent' ? 0 : u === 'warning' ? 1 : 2
      return rank(ua) - rank(ub)
    })
  const recentGroups = entries.filter(([, blocks]) => !blocks.some(b => b.showsInInbox === 1))

  return (
    <div className="flex flex-col h-full">
      {/* Nav */}
      <div className="flex items-center justify-between px-4 pt-12 pb-3 flex-shrink-0">
        <h1 className="text-xl font-bold text-white">Ask</h1>
        <span className="text-xs text-ask-secondary">MockAskMac</span>
      </div>

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

      {/* Alert chips — only when there are needs-response scripts */}
      {needsResponseGroups.length > 0 && (
        <div className="flex-shrink-0 border-t border-ask-sep/50 px-4 py-2">
          <div className="flex gap-2 overflow-x-auto no-scrollbar">
            {needsResponseGroups.map(([scriptID, blocks]) => (
              <AlertChip
                key={scriptID}
                scriptID={scriptID}
                blocks={blocks}
                onClick={() => navigate(`/script/${scriptID}`)}
              />
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
