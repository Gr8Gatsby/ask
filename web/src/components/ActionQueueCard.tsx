import { useNavigate } from 'react-router-dom'
import type { Block, TilePayload, Urgency, QuickReplyPayload } from '../lib/types'
import ScriptIcon from './shared/ScriptIcon'
import UrgencyBadge from './shared/UrgencyBadge'
import QuickReplyBlock from './blocks/QuickReplyBlock'

// ---- helpers ----

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

function dominantUrgency(inboxBlocks: Block[]): Urgency {
  const urgencies = inboxBlocks
    .map(b => parsePayload<{ urgency?: Urgency }>(b.payload)?.urgency)
  if (urgencies.includes('urgent'))  return 'urgent'
  if (urgencies.includes('info'))    return 'info'
  return 'warning'
}

const DOT: Record<string, string> = {
  green: 'bg-ask-green', blue: 'bg-ask-blue', orange: 'bg-ask-orange',
  red: 'bg-ask-red',     yellow: 'bg-ask-yellow',
}

// ---- component ----

interface Props {
  scriptID: string
  blocks: Block[]
  onRespond: (blockID: string, value: string) => void
}

export default function ActionQueueCard({ scriptID, blocks, onRespond }: Props) {
  const navigate = useNavigate()
  const first = blocks[0]

  const tilePayload = parsePayload<TilePayload>(
    blocks.find(b => b.blockType === 'tile')?.payload ?? 'null'
  )

  const inboxBlocks = blocks.filter(b => b.showsInInbox === 1)
  const urgency = dominantUrgency(inboxBlocks)

  // Highest-priority quick_reply for inline rendering (mirrors iOS logic)
  const urgencyRank = (u?: Urgency) => u === 'urgent' ? 0 : u === 'info' ? 2 : 1
  const quickReplyBlock = inboxBlocks
    .filter(b => b.blockType === 'quick_reply')
    .sort((a, b) => {
      const ua = urgencyRank(parsePayload<{ urgency?: Urgency }>(a.payload)?.urgency)
      const ub = urgencyRank(parsePayload<{ urgency?: Urgency }>(b.payload)?.urgency)
      return ua !== ub ? ua - ub : new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
    })[0]

  const borderCls = urgency === 'urgent'
    ? 'border-ask-red/50'
    : urgency === 'info'
    ? 'border-ask-sep'
    : 'border-ask-orange/50'

  return (
    <div className={`bg-ask-card rounded-xl border ${borderCls} overflow-hidden`}>
      {/* Script header row — always navigates to script detail */}
      <button
        onClick={() => navigate(`/script/${scriptID}`)}
        className="w-full flex items-center gap-3 px-3.5 py-3.5 hover:bg-ask-text/[0.05] transition-colors text-left"
      >
        <ScriptIcon
          scriptIconData={first.scriptIconData}
          scriptIconSVG={first.scriptIconSVG}
          scriptIcon={first.scriptIcon}
          scriptName={first.scriptName}
          size={30}
        />
        <div className="flex-1 min-w-0">
          <p className="text-[15px] font-semibold text-ask-text leading-tight">{first.scriptName}</p>
          {tilePayload && (
            <div className="flex items-center gap-1.5 mt-0.5">
              <div className={`w-1.5 h-1.5 rounded-full ${DOT[tilePayload.status_color ?? ''] ?? 'bg-ask-secondary'}`} />
              <span className="text-xs text-ask-secondary">{tilePayload.label}</span>
            </div>
          )}
        </div>
        <UrgencyBadge urgency={urgency} />
        {!quickReplyBlock && (
          <span className="text-ask-secondary ml-1">›</span>
        )}
      </button>

      {/* Inline quick_reply */}
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
