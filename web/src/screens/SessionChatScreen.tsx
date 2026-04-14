import { useState, useEffect, useRef } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import { useTheme } from '../lib/PlatformContext'
import { useSettings } from '../lib/SettingsContext'
import { getTaskMessages } from '../lib/api'
import type { AgentSessionPayload, TaskMessage } from '../lib/types'
import Markdown from '../components/shared/Markdown'

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

// ---- Message part rendering (same as TaskThreadScreen) ----

interface Part { type: string; text?: string; name?: string; input?: unknown; content?: unknown; source?: unknown; thinking?: string }

function renderPart(p: Part, i: number) {
  if (p.type === 'text' && p.text) {
    return <Markdown key={i}>{p.text}</Markdown>
  }
  if (p.type === 'tool_use') {
    return (
      <span key={i} className="text-[10px] font-mono text-ask-secondary/70 bg-ask-card2 px-1.5 py-0.5 rounded">
        ⚙ {p.name}
      </span>
    )
  }
  if (p.type === 'tool_result') {
    const text = typeof p.content === 'string' ? p.content : ''
    return (
      <span key={i} className="text-[10px] font-mono text-ask-secondary/60 line-clamp-2">
        {text.slice(0, 120)}
      </span>
    )
  }
  if (p.type === 'thinking' && p.thinking) {
    return (
      <span key={i} className="text-[10px] italic text-ask-secondary/50">
        {p.thinking.slice(0, 80)}…
      </span>
    )
  }
  if (p.type === 'image') {
    return <span key={i} className="text-[10px] text-ask-secondary">[image]</span>
  }
  if (p.type === 'document') {
    return <span key={i} className="text-[10px] text-ask-secondary">[document]</span>
  }
  return null
}

// ---- Tool status line ----

const TOOL_ICONS: Record<string, string> = {
  Edit: '✏️', Write: '📝', Read: '📖', Bash: '⚡', Glob: '🔍',
  Grep: '🔎', Agent: '🤖', WebFetch: '🌐', WebSearch: '🌐',
}

function ToolStatusLine({ tool, preview, color }: { tool: string; preview?: string; color: string }) {
  return (
    <div className="flex items-center gap-1.5 mb-2">
      <span className="text-xs">{TOOL_ICONS[tool] ?? '⚙'}</span>
      <span className="text-xs font-mono" style={{ color }}>{tool}</span>
      {preview && (
        <span className="text-xs text-ask-secondary truncate max-w-[180px]">{preview}</span>
      )}
    </div>
  )
}

// ---- Tool history timeline ----

function ToolHistoryTimeline({
  entries,
  color,
}: {
  entries: Array<{ tool: string; preview: string; timestamp: string }>
  color: string
}) {
  function relTime(ts: string) {
    const diff = Date.now() - new Date(ts).getTime()
    if (diff < 60_000) return 'just now'
    return `${Math.floor(diff / 60_000)}m ago`
  }

  return (
    <div className="flex flex-col gap-1 mb-2">
      {entries.map((e, i) => (
        <div key={i} className="flex items-center gap-1.5">
          <span className="text-[10px]">{TOOL_ICONS[e.tool] ?? '⚙'}</span>
          <span className="text-[10px] font-mono font-semibold" style={{ color }}>{e.tool}</span>
          <span className="text-[10px] text-ask-secondary/70 truncate flex-1 min-w-0">{e.preview}</span>
          <span className="text-[9px] text-ask-secondary/50 flex-shrink-0">{relTime(e.timestamp)}</span>
        </div>
      ))}
    </div>
  )
}

// ---- Last message context bar ----

function LastMessageBar({ message, color }: { message: string; color: string }) {
  const firstLine = message.split('\n').find(l => l.trim()) ?? message
  const preview = firstLine.replace(/^#+\s*/, '').replace(/\*\*/g, '').slice(0, 150)
  return (
    <div
      className="flex-shrink-0 px-4 py-2.5 border-b border-ask-sep/50 bg-ask-card/60"
      style={{ borderLeftWidth: 3, borderLeftColor: color }}
    >
      <p className="text-[11px] text-ask-secondary leading-snug line-clamp-2">{preview}</p>
    </div>
  )
}

// ---- Pending confirmation bar ----

function PendingConfirmationBar({
  title,
  body,
  options,
  onRespond,
  accentColor,
}: {
  title: string
  body?: string
  options: string[]
  onRespond: (value: string) => void
  accentColor: string
}) {
  return (
    <div className="border-t border-ask-sep/50 bg-ask-orange/5 px-4 pt-3 pb-3" style={{ borderTopColor: `${accentColor}40` }}>
      <p className="text-xs font-semibold text-ask-text mb-1.5">{title}</p>
      {body && (
        <p className="text-[13px] font-mono text-ask-text mb-2.5 leading-snug bg-ask-card2 px-2.5 py-1.5 rounded-lg break-all border border-ask-sep/30">
          {body}
        </p>
      )}
      <div className="flex flex-wrap gap-2">
        {options.map(opt => {
          const lc = opt.toLowerCase()
          const isAlways = lc.startsWith('always')
          const isDeny = lc === 'deny' || lc === 'no' || lc.startsWith('deny')
          const label = isAlways ? 'Always' : isDeny ? 'Deny' : opt
          return (
            <button
              key={opt}
              onClick={() => onRespond(opt)}
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
  )
}

// ---- Screen ----

export default function SessionChatScreen() {
  const { scriptID, sessionID } = useParams<{ scriptID: string; sessionID: string }>()
  const navigate = useNavigate()
  const theme = useTheme()
  const { useBrandColors } = useSettings()
  const { blocks: allBlocks, respond } = useBlocks()
  const [reply, setReply] = useState('')
  const [sending, setSending] = useState(false)
  const [messages, setMessages] = useState<TaskMessage[]>([])
  const bottomRef = useRef<HTMLDivElement>(null)

  const sessionBlock = allBlocks.find(b => {
    if (b.blockType !== 'agent_session' || b.scriptID !== scriptID) return false
    return parsePayload<AgentSessionPayload>(b.payload)?.session_id === sessionID
  })

  const payload = sessionBlock ? parsePayload<AgentSessionPayload>(sessionBlock.payload) : null
  const accentColor = useBrandColors ? (payload?.brand_color ?? '#8E8E93') : '#8E8E93'

  // Load chat history from task messages
  useEffect(() => {
    if (!payload?.task_id) return
    getTaskMessages(payload.task_id).then(setMessages)
  }, [payload?.task_id])

  // Scroll to bottom on new messages
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages, payload?.last_message])

  const handleSend = async (text: string) => {
    if (!text.trim() || !sessionBlock || sending) return
    setSending(true)
    await respond(sessionBlock.blockID, text.trim())
    setReply('')
    setSending(false)
  }

  const handleStop = async () => {
    if (!sessionBlock) return
    await respond(sessionBlock.blockID, '__close_session__')
  }

  const handlePermissionToggle = async () => {
    if (!sessionBlock) return
    await respond(sessionBlock.blockID, '__permissions__')
  }

  return (
    <div className="flex flex-col h-full">
      {/* Nav bar */}
      <div className="flex items-center gap-3 px-4 pt-3 pb-3 border-b border-ask-sep flex-shrink-0">
        <button onClick={() => navigate(-1)} className={`flex-shrink-0 ${theme.navBackClass}`}>
          {theme.navBackIcon}
          {!theme.isAndroid && <span>Back</span>}
        </button>
        <div className="flex items-center gap-2 flex-1 min-w-0">
          {payload?.is_working && (
            <div className="w-2 h-2 rounded-full flex-shrink-0 animate-pulse" style={{ backgroundColor: accentColor }} />
          )}
          <div className="min-w-0 flex-1">
            <p className="text-sm font-semibold text-ask-text truncate">{payload?.project ?? sessionID}</p>
            <div className="flex items-center gap-2">
              <p className="text-[10px] text-ask-secondary">{payload?.agent_name ?? 'Claude Code'}</p>
              {payload?.permission_mode && (
                <button
                  onClick={handlePermissionToggle}
                  className="text-[10px] px-1.5 py-0.5 rounded bg-ask-card2 text-ask-secondary hover:text-ask-text transition-colors"
                >
                  {payload.permission_mode === 'full-auto' ? 'auto' : 'supervised'}
                </button>
              )}
            </div>
          </div>
        </div>
        <div className="flex items-center gap-2 flex-shrink-0">
          {payload?.task_id && (
            <button onClick={() => navigate(`/tasks/${payload.task_id}`)} className="text-xs text-ask-blue">
              Feed
            </button>
          )}
          {sessionBlock && (
            <button
              onClick={handleStop}
              className="text-xs text-ask-red font-medium border border-ask-red/30 px-2 py-0.5 rounded-lg hover:bg-ask-red/10 transition-colors"
            >
              Stop
            </button>
          )}
        </div>
      </div>

      {/* Last message context bar — shown when working and there's a previous message */}
      {payload?.is_working && payload.last_message && (
        <LastMessageBar message={payload.last_message} color={accentColor} />
      )}

      {/* Chat history */}
      <div className="flex-1 overflow-y-auto no-scrollbar px-4 py-3 flex flex-col gap-2">
        {!sessionBlock ? (
          <div className="flex items-center justify-center h-24 text-ask-secondary text-sm">Session ended</div>
        ) : (
          <>
            {/* Task message history */}
            {messages.map(msg => {
              let parts: Part[] = []
              try { parts = JSON.parse(msg.partsJSON) } catch { /* */ }
              const textParts = parts.filter(p => p.type === 'text' && p.text)
              if (textParts.length === 0 && parts.some(p => p.type === 'tool_use' || p.type === 'tool_result')) {
                // Tool-only message — skip in session chat (shown in feed thread)
                return null
              }
              return (
                <div key={msg.messageID} className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                  <div className={`max-w-[85%] rounded-2xl px-3 py-2 text-sm ${
                    msg.role === 'user'
                      ? 'bg-ask-blue text-white rounded-br-sm'
                      : 'bg-ask-card text-ask-text rounded-bl-sm'
                  }`}>
                    {parts.map((p, i) => renderPart(p, i))}
                  </div>
                </div>
              )
            })}

            {/* Live status — current tool or last message */}
            <div className="flex justify-start">
              <div className="max-w-[85%] bg-ask-card rounded-2xl rounded-bl-sm px-3 py-2.5">
                <div className="flex items-center gap-2 mb-2">
                  <div
                    className="w-5 h-5 rounded-full flex items-center justify-center text-[9px] font-bold text-white flex-shrink-0"
                    style={{ backgroundColor: accentColor }}
                  >
                    {(payload?.agent_name ?? 'C')[0]}
                  </div>
                  <span className="text-[10px] font-semibold text-ask-secondary">
                    {payload?.agent_name ?? 'Claude Code'}
                  </span>
                </div>
                {payload?.is_working ? (
                  <>
                    {payload.tool_history && payload.tool_history.length > 0 && (
                      <ToolHistoryTimeline entries={payload.tool_history.slice(-5)} color={accentColor} />
                    )}
                    {payload.current_tool && (
                      <ToolStatusLine tool={payload.current_tool} preview={payload.current_preview} color={accentColor} />
                    )}
                    <div className="flex items-center gap-2">
                      {[0, 1, 2].map(i => (
                        <div key={i} className="w-1.5 h-1.5 rounded-full animate-bounce"
                          style={{ backgroundColor: accentColor, animationDelay: `${i * 0.15}s` }} />
                      ))}
                      <span className="text-xs text-ask-secondary ml-1">Working…</span>
                    </div>
                  </>
                ) : payload?.last_message ? (
                  <Markdown>{payload.last_message}</Markdown>
                ) : (
                  <span className="text-xs text-ask-secondary">Session started</span>
                )}
              </div>
            </div>
            <div ref={bottomRef} />
          </>
        )}
      </div>

      {/* Pending confirmation bar — above compose */}
      {sessionBlock && payload?.pending_confirmation && (
        <PendingConfirmationBar
          title={payload.pending_confirmation.title}
          body={payload.pending_confirmation.body}
          options={payload.pending_confirmation.options}
          accentColor={accentColor}
          onRespond={val => handleSend(val)}
        />
      )}

      {/* Compose bar */}
      {sessionBlock && (
        <div className="flex-shrink-0 px-4 py-3 border-t border-ask-sep/50">
          <div className="flex gap-2 items-center">
            <input
              type="text"
              value={reply}
              onChange={e => setReply(e.target.value)}
              placeholder={payload?.placeholder ?? 'Reply to Claude…'}
              disabled={sending}
              onKeyDown={e => { if (e.key === 'Enter') handleSend(reply) }}
              className={`flex-1 disabled:opacity-50 ${theme.input}`}
            />
            <button
              onClick={() => handleSend(reply)}
              disabled={!reply.trim() || sending}
              className={`disabled:opacity-40 flex-shrink-0 ${
                theme.isAndroid
                  ? 'w-10 h-10 rounded-full flex items-center justify-center'
                  : 'px-4 py-2.5 rounded-xl text-sm font-semibold text-white'
              }`}
              style={{ backgroundColor: accentColor }}
            >
              {theme.isAndroid
                ? <span className="mat-icon text-white" style={{ fontSize: 20, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 20" }}>send</span>
                : (sending ? '…' : '→')}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
