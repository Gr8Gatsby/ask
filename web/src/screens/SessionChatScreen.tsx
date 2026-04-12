import { useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import type { AgentSessionPayload, ConfirmationPayload } from '../lib/types'
import Markdown from '../components/shared/Markdown'
import BlockRenderer from '../components/blocks/BlockRenderer'

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

export default function SessionChatScreen() {
  const { scriptID, sessionID } = useParams<{ scriptID: string; sessionID: string }>()
  const navigate = useNavigate()
  const { blocks: allBlocks, respond } = useBlocks()
  const [reply, setReply] = useState('')
  const [sending, setSending] = useState(false)

  // Find the agent_session block for this session
  const sessionBlock = allBlocks.find(b => {
    if (b.blockType !== 'agent_session' || b.scriptID !== scriptID) return false
    return parsePayload<AgentSessionPayload>(b.payload)?.session_id === sessionID
  })

  const payload = sessionBlock ? parsePayload<AgentSessionPayload>(sessionBlock.payload) : null
  const accentColor = payload?.brand_color ?? '#74AA9C'

  // Confirmation blocks linked to this session
  const linkedConfirmations = allBlocks.filter(b => {
    if (b.blockType !== 'confirmation' || b.scriptID !== scriptID) return false
    return parsePayload<ConfirmationPayload>(b.payload)?.session_id === sessionID
  })

  const handleSend = async () => {
    if (!reply.trim() || !sessionBlock || sending) return
    setSending(true)
    await respond(sessionBlock.blockID, reply.trim())
    setReply('')
    setSending(false)
  }

  return (
    <div className="flex flex-col h-full">
      {/* Nav bar */}
      <div className="flex items-center gap-3 px-4 pt-12 pb-3 border-b border-ask-sep flex-shrink-0">
        <button onClick={() => navigate(-1)} className="text-ask-blue text-sm font-medium flex-shrink-0">
          ‹ Back
        </button>
        <div className="flex items-center gap-2 flex-1 min-w-0">
          {payload?.is_working && (
            <div
              className="w-2 h-2 rounded-full flex-shrink-0 animate-pulse"
              style={{ backgroundColor: accentColor }}
            />
          )}
          <div className="min-w-0">
            <p className="text-sm font-semibold text-white truncate">{payload?.project ?? sessionID}</p>
            <p className="text-[10px] text-ask-secondary">{payload?.agent_name ?? 'Claude Code'}</p>
          </div>
        </div>
        {payload?.task_id && (
          <button
            onClick={() => navigate(`/tasks/${payload.task_id}`)}
            className="text-xs text-ask-blue hover:underline flex-shrink-0"
          >
            View Feed
          </button>
        )}
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto no-scrollbar px-4 py-4 flex flex-col gap-3">
        {!sessionBlock ? (
          <div className="flex items-center justify-center h-24 text-ask-secondary text-sm">Session ended</div>
        ) : (
          <>
            {/* Agent's last message */}
            <div className="bg-ask-card rounded-xl p-3.5 border border-ask-sep">
              <div className="flex items-center gap-2 mb-2.5">
                <div
                  className="w-5 h-5 rounded-full flex items-center justify-center text-[9px] font-bold text-white flex-shrink-0"
                  style={{ backgroundColor: accentColor }}
                >
                  {(payload?.agent_name ?? 'C')[0]}
                </div>
                <span className="text-xs font-semibold text-ask-secondary">
                  {payload?.agent_name ?? 'Claude Code'}
                </span>
              </div>

              {payload?.is_working ? (
                <div className="flex items-center gap-2">
                  {[0, 1, 2].map(i => (
                    <div
                      key={i}
                      className="w-1.5 h-1.5 rounded-full animate-bounce"
                      style={{ backgroundColor: accentColor, animationDelay: `${i * 0.15}s` }}
                    />
                  ))}
                  <span className="text-xs text-ask-secondary ml-1">Working…</span>
                </div>
              ) : payload?.last_message ? (
                <Markdown>{payload.last_message}</Markdown>
              ) : (
                <span className="text-xs text-ask-secondary">Session started</span>
              )}
            </div>

            {/* Linked confirmation/permission blocks */}
            {linkedConfirmations.map(block => (
              <div key={block.blockID} className="bg-ask-orange/5 rounded-xl border border-ask-orange/30 p-3.5">
                <BlockRenderer block={block} onRespond={respond} />
              </div>
            ))}
          </>
        )}
      </div>

      {/* Reply input */}
      {sessionBlock && (
        <div className="flex-shrink-0 px-4 py-3 border-t border-ask-sep">
          <div className="flex gap-2">
            <input
              type="text"
              value={reply}
              onChange={e => setReply(e.target.value)}
              placeholder={payload?.placeholder ?? 'Reply to Claude…'}
              disabled={sending}
              onKeyDown={e => { if (e.key === 'Enter') handleSend() }}
              className="flex-1 bg-ask-card rounded-xl px-4 py-2.5 text-sm text-white placeholder-ask-secondary outline-none focus:ring-1 disabled:opacity-50"
              style={{ '--tw-ring-color': accentColor } as React.CSSProperties}
            />
            <button
              onClick={handleSend}
              disabled={!reply.trim() || sending}
              className="px-4 py-2.5 rounded-xl text-white text-sm font-semibold disabled:opacity-40 transition-opacity hover:opacity-80"
              style={{ backgroundColor: accentColor }}
            >
              {sending ? '…' : '→'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
