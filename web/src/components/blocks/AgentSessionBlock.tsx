import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import type { Block, AgentSessionPayload } from '../../lib/types'
import Markdown from '../shared/Markdown'

interface Props {
  block: Block
  payload: AgentSessionPayload
  onRespond: (blockID: string, value: string) => void
}

export default function AgentSessionBlock({ block, payload, onRespond }: Props) {
  const [reply, setReply] = useState('')
  const [collapsed, setCollapsed] = useState(false)
  const navigate = useNavigate()

  const accentColor = payload.brand_color ?? '#74AA9C'

  const submit = () => {
    if (!reply.trim()) return
    onRespond(block.blockID, reply.trim())
    setReply('')
  }

  return (
    <div className="flex flex-col gap-2">
      {/* Header row */}
      <div className="flex items-center gap-2">
        <div
          className="w-2 h-2 rounded-full flex-shrink-0"
          style={{ backgroundColor: payload.is_working ? accentColor : '#8e8e93' }}
        />
        <span className="flex-1 text-sm font-semibold text-white truncate">{payload.project}</span>
        {payload.task_id && (
          <button
            onClick={() => navigate(`/tasks/${payload.task_id}`)}
            className="text-[10px] text-ask-blue hover:underline"
          >
            View Feed
          </button>
        )}
        <button
          onClick={() => setCollapsed(c => !c)}
          className="text-ask-secondary text-xs hover:text-white transition-colors"
        >
          {collapsed ? '▼' : '▲'}
        </button>
      </div>

      {collapsed ? (
        <p className="text-xs text-ask-secondary truncate">{payload.last_message ?? 'Working...'}</p>
      ) : (
        <>
          {/* Last message */}
          <div className="bg-black/20 rounded-lg p-3 border border-ask-sep min-h-[48px]">
            {payload.is_working ? (
              <div className="flex items-center gap-2">
                <div className="flex gap-1">
                  {[0, 1, 2].map(i => (
                    <div
                      key={i}
                      className="w-1.5 h-1.5 rounded-full animate-bounce"
                      style={{ backgroundColor: accentColor, animationDelay: `${i * 0.15}s` }}
                    />
                  ))}
                </div>
                <span className="text-xs text-ask-secondary">Working...</span>
              </div>
            ) : payload.last_message ? (
              <Markdown>{payload.last_message}</Markdown>
            ) : (
              <span className="text-xs text-ask-secondary">Session started</span>
            )}
          </div>

          {/* Reply row */}
          <div className="flex gap-2">
            <input
              type="text"
              value={reply}
              onChange={e => setReply(e.target.value)}
              placeholder={payload.placeholder ?? 'Reply to Claude...'}
              onKeyDown={e => { if (e.key === 'Enter') submit() }}
              className="flex-1 bg-ask-card2 rounded-lg px-3 py-2 text-sm text-white placeholder-ask-secondary outline-none focus:ring-1 focus:ring-ask-blue"
            />
            <button
              onClick={submit}
              disabled={!reply.trim()}
              className="px-4 py-2 rounded-lg text-white text-sm font-semibold disabled:opacity-40 transition-colors hover:opacity-80"
              style={{ backgroundColor: accentColor }}
            >
              →
            </button>
          </div>
        </>
      )}
    </div>
  )
}
