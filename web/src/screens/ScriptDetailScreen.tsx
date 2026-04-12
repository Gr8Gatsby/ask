import { useNavigate, useParams } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import type { AgentSessionPayload, ConfirmationPayload } from '../lib/types'
import BlockRenderer from '../components/blocks/BlockRenderer'
import ScriptIcon from '../components/shared/ScriptIcon'
import StartSessionBlock from '../components/blocks/StartSessionBlock'

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

// ---- Session row ----

function SessionRow({
  block,
  confirmationCount,
  onClick,
}: {
  block: ReturnType<typeof useBlocks>['blocks'][number]
  confirmationCount: number
  onClick: () => void
}) {
  const payload = parsePayload<AgentSessionPayload>(block.payload)
  if (!payload) return null

  return (
    <button
      onClick={onClick}
      className="w-full flex items-center gap-3 py-3 px-0 hover:bg-white/5 -mx-4 px-4 transition-colors text-left"
    >
      <div
        className={`w-2 h-2 rounded-full flex-shrink-0 ${payload.is_working ? 'bg-ask-blue animate-pulse' : 'bg-ask-card2'}`}
      />
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-white">{payload.project}</p>
        <p className="text-xs text-ask-secondary truncate">
          {payload.is_working
            ? `${payload.agent_name ?? 'Claude'} is working…`
            : (payload.last_message?.split('\n').find(l => l.trim()) ?? 'Session started')}
        </p>
      </div>
      <div className="flex items-center gap-2 flex-shrink-0">
        {confirmationCount > 0 && (
          <span className="text-[10px] font-bold bg-ask-orange/20 text-ask-orange px-1.5 py-0.5 rounded-full min-w-[20px] text-center">
            {confirmationCount}
          </span>
        )}
        <span className="text-ask-secondary">›</span>
      </div>
    </button>
  )
}

// ---- Screen ----

export default function ScriptDetailScreen() {
  const { scriptID } = useParams<{ scriptID: string }>()
  const navigate = useNavigate()
  const { blocks: allBlocks, respond } = useBlocks()
  const blocks = allBlocks.filter(b => b.scriptID === scriptID)
  const first = blocks[0]

  const sessionBlocks = blocks.filter(b => b.blockType === 'agent_session')
  const liveSessionIDs = new Set(
    sessionBlocks.map(b => parsePayload<AgentSessionPayload>(b.payload)?.session_id ?? '')
  )

  // Header section: non-session, non-tile, non-startSession, non-feedItem
  // Exclude confirmations that are linked to a live session (shown under their session instead)
  const headerBlocks = blocks.filter(b => {
    if (['agent_session', 'tile', 'start_session', 'feed_item'].includes(b.blockType)) return false
    if (b.blockType === 'confirmation') {
      const sid = parsePayload<ConfirmationPayload>(b.payload)?.session_id
      if (sid && liveSessionIDs.has(sid)) return false
    }
    return true
  })

  const startSessionBlock = blocks.find(b => b.blockType === 'start_session')

  function sessionConfirmations(sessionId: string) {
    return blocks.filter(b => {
      if (b.blockType !== 'confirmation') return false
      return parsePayload<ConfirmationPayload>(b.payload)?.session_id === sessionId
    })
  }

  const isEmpty = headerBlocks.length === 0 && sessionBlocks.length === 0

  return (
    <div className="flex flex-col h-full">
      {/* Nav bar */}
      <div className="flex items-center gap-3 px-4 pt-12 pb-3 border-b border-ask-sep flex-shrink-0">
        <button onClick={() => navigate(-1)} className="text-ask-blue text-sm font-medium">‹ Home</button>
        {first && (
          <div className="flex items-center gap-2 flex-1 min-w-0">
            <ScriptIcon
              scriptIconData={first.scriptIconData}
              scriptIconSVG={first.scriptIconSVG}
              scriptIcon={first.scriptIcon}
              scriptName={first.scriptName}
              size={24}
            />
            <span className="text-sm font-semibold text-white truncate">{first.scriptName}</span>
          </div>
        )}
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto no-scrollbar">
        {isEmpty ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No active blocks</div>
        ) : (
          <div className="flex flex-col">
            {/* Header blocks */}
            {headerBlocks.map(block => (
              <div key={block.blockID} className="px-4 py-3 border-b border-ask-sep">
                <BlockRenderer block={block} onRespond={respond} />
              </div>
            ))}

            {/* Sessions section */}
            {sessionBlocks.length > 0 && (
              <div className="mt-1">
                <p className="px-4 pt-3 pb-1 text-xs font-semibold text-ask-secondary uppercase tracking-wide">
                  Sessions
                </p>
                {sessionBlocks.map(block => {
                  const payload = parsePayload<AgentSessionPayload>(block.payload)
                  const confs = payload ? sessionConfirmations(payload.session_id) : []
                  return (
                    <div key={block.blockID}>
                      {/* Session row */}
                      <div className={`px-4 border-b border-ask-sep ${confs.length > 0 ? 'bg-ask-orange/5' : ''}`}>
                        <SessionRow
                          block={block}
                          confirmationCount={confs.length}
                          onClick={() => {
                            if (payload) navigate(`/script/${scriptID}/session/${payload.session_id}`)
                          }}
                        />
                      </div>

                      {/* Linked confirmations — indented, orange tint */}
                      {confs.map(conf => (
                        <div key={conf.blockID} className="pl-8 pr-4 py-3 border-b border-ask-sep bg-ask-orange/5">
                          <BlockRenderer block={conf} onRespond={respond} />
                        </div>
                      ))}
                    </div>
                  )
                })}
              </div>
            )}
          </div>
        )}
      </div>

      {/* Bottom bar — "+" start session button */}
      {startSessionBlock && (
        <div className="flex-shrink-0 px-4 py-3 border-t border-ask-sep flex items-center justify-between">
          <StartSessionBlock block={startSessionBlock} payload={JSON.parse(startSessionBlock.payload)} onRespond={respond} />
        </div>
      )}
    </div>
  )
}
