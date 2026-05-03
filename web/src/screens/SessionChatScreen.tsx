import { useState, useEffect, useRef } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import { useTheme, usePlatform } from '../lib/PlatformContext'
import { useSettings } from '../lib/SettingsContext'
import { useBrandColor, IOSStatusBarRow, iosNavChromeStyle } from '../components/layout/AppShell'
import { getTaskMessages } from '../lib/api'
import type { AgentSessionPayload, TaskMessage } from '../lib/types'
import Markdown from '../components/shared/Markdown'

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

// ---- Message part rendering (same as TaskThreadScreen) ----

interface Part { type: string; text?: string; name?: string; input?: unknown; content?: unknown; source?: unknown; thinking?: string }

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

// ---- Local message model ----

interface LocalMessage {
  key: string
  role: 'user' | 'assistant' | 'approval'
  text: string
  approvalTitle?: string
  approvalBody?: string
}

function extractText(partsJSON: string): string {
  try {
    const parts = JSON.parse(partsJSON) as Part[]
    return parts.filter(p => p.type === 'text' && p.text).map(p => p.text!).join('\n')
  } catch { return '' }
}

// ---- Screen ----

export default function SessionChatScreen() {
  const { scriptID, sessionID } = useParams<{ scriptID: string; sessionID: string }>()
  const navigate = useNavigate()
  const theme = useTheme()
  const { themeMode } = usePlatform()
  const isLight = themeMode === 'light'
  const { useBrandColors } = useSettings()
  const { blocks: allBlocks, respond } = useBlocks()
  const [reply, setReply] = useState('')
  const [sending, setSending] = useState(false)
  const [localMessages, setLocalMessages] = useState<LocalMessage[]>([])
  const lastAssistantText = useRef('')
  const bottomRef = useRef<HTMLDivElement>(null)

  const sessionBlock = allBlocks.find(b => {
    if (b.blockType !== 'agent_session' || b.scriptID !== scriptID) return false
    return parsePayload<AgentSessionPayload>(b.payload)?.session_id === sessionID
  })

  const payload = sessionBlock ? parsePayload<AgentSessionPayload>(sessionBlock.payload) : null
  const accentColor = useBrandColors ? (payload?.brand_color ?? '#8E8E93') : '#8E8E93'

  // Push brand color to AppShell so status bar + nav are seamlessly tinted
  const { setBrandColor: setAppBrandColor } = useBrandColor()
  useEffect(() => {
    if (!theme.isAndroid) setAppBrandColor(accentColor !== '#8E8E93' ? accentColor : null)
    return () => setAppBrandColor(null)
  }, [accentColor, theme.isAndroid]) // eslint-disable-line react-hooks/exhaustive-deps

  // Seed history from CloudKit task messages on mount / task_id change
  useEffect(() => {
    if (!payload?.task_id) return
    getTaskMessages(payload.task_id).then((msgs: TaskMessage[]) => {
      const loaded: LocalMessage[] = msgs
        .map(m => ({ key: m.messageID, role: m.role, text: extractText(m.partsJSON) }))
        .filter(m => m.text)
      setLocalMessages(loaded)
      // Track last assistant text so we don't re-append it from last_message
      const lastAsst = [...loaded].reverse().find(m => m.role === 'assistant')
      if (lastAsst) lastAssistantText.current = lastAsst.text
    })
  }, [payload?.task_id]) // eslint-disable-line react-hooks/exhaustive-deps

  // Append new assistant message when last_message changes
  useEffect(() => {
    const msg = payload?.last_message
    if (!msg || msg === lastAssistantText.current) return
    lastAssistantText.current = msg
    setLocalMessages(prev => {
      const last = prev[prev.length - 1]
      if (last?.role === 'assistant' && last.text === msg) return prev
      return [...prev, { key: `live-${Date.now()}`, role: 'assistant', text: msg }]
    })
  }, [payload?.last_message])

  // Scroll to bottom on new messages
  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [localMessages.length, payload?.is_working])

  const handleSend = async (text: string) => {
    if (!text.trim() || !sessionBlock || sending) return
    setSending(true)
    // Optimistically add user message so it appears immediately
    setLocalMessages(prev => [...prev, { key: `user-${Date.now()}`, role: 'user', text: text.trim() }])
    await respond(sessionBlock.blockID, text.trim())
    setReply('')
    setSending(false)
  }

  const handleApprove = async (value: string) => {
    if (!sessionBlock || sending) return
    setSending(true)
    const pc = payload?.pending_confirmation
    setLocalMessages(prev => [...prev, {
      key: `approval-${Date.now()}`,
      role: 'approval',
      text: value,
      approvalTitle: pc?.title,
      approvalBody: pc?.body,
    }])
    await respond(sessionBlock.blockID, value)
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

  // Nav bar — Android: full info; iOS: Back + working dot + ✕ only
  const androidNavBar = (
    <>
      <button onClick={() => navigate(-1)} className={`flex-shrink-0 flex items-center gap-1 ${theme.navBackClass}`}>
        {theme.navBackIcon}
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
    </>
  )

  const iosNavBar = (
    <>
      {/* Back — plain nav link, same style as ScriptDetailScreen */}
      <button onClick={() => navigate(-1)} className={theme.navBackClass}>
        {theme.navBackIcon}
        <span>Back</span>
      </button>

      {/* Working indicator + session name in center */}
      <div className="flex-1 flex items-center justify-center gap-2 min-w-0 px-2">
        {payload?.is_working && (
          <div className="w-2 h-2 rounded-full animate-pulse flex-shrink-0" style={{ backgroundColor: accentColor }} />
        )}
        {payload?.project && (
          <span className="text-[15px] font-semibold text-ask-text truncate">{payload.project}</span>
        )}
      </div>

      {/* Stop — plain text button */}
      {sessionBlock && (
        <button
          onClick={handleStop}
          className="text-[15px] font-medium text-ask-blue"
        >
          Stop
        </button>
      )}
    </>
  )

  // Gradient is handled by AppShell via BrandColorContext (brand color pushed in useEffect above)

  // Shared chat history content
  const chatHistory = (
    <div className="px-4 py-3 flex flex-col gap-2">
      {!sessionBlock ? (
        <div className="flex items-center justify-center h-24 text-ask-secondary text-sm">Session ended</div>
      ) : (
        <>
          {localMessages.map(msg => {
            if (msg.role === 'user') {
              return (
                <div key={msg.key} className="flex justify-end">
                  <div className="max-w-[80%] rounded-[20px] rounded-br-[5px] px-3.5 py-2.5 bg-ask-blue text-white text-[15px] leading-snug">
                    {msg.text}
                  </div>
                </div>
              )
            }
            if (msg.role === 'approval') {
              const lc = msg.text.toLowerCase()
              const isDeny = lc === 'deny' || lc.startsWith('deny')
              return (
                <div key={msg.key} className="flex justify-end">
                  <div className="max-w-[85%] rounded-2xl rounded-br-[5px] overflow-hidden border border-ask-sep/50 bg-ask-card2 text-right">
                    {(msg.approvalTitle || msg.approvalBody) && (
                      <div className="px-3 pt-2.5 pb-2 border-b border-ask-sep/40 text-left">
                        {msg.approvalTitle && (
                          <p className="text-[11px] font-semibold text-ask-secondary mb-1">{msg.approvalTitle}</p>
                        )}
                        {msg.approvalBody && (
                          <p className="text-[12px] font-mono text-ask-text leading-snug break-all">{msg.approvalBody}</p>
                        )}
                      </div>
                    )}
                    <div className={`px-3 py-2 text-[13px] font-semibold ${isDeny ? 'text-ask-red' : 'text-ask-green'}`}>
                      {msg.text}
                    </div>
                  </div>
                </div>
              )
            }
            return (
              <div key={msg.key} className="text-ask-text text-[15px]">
                <Markdown>{msg.text}</Markdown>
              </div>
            )
          })}

          {/* Agent name + working indicator (only shown while working or on empty state) */}
          {(payload?.is_working || localMessages.length === 0) && (
            <div className="flex flex-col gap-1.5">
              <div className="flex items-center gap-1.5">
                <div
                  className="w-4 h-4 rounded-full flex items-center justify-center text-[8px] font-bold text-white flex-shrink-0"
                  style={{ backgroundColor: accentColor }}
                >
                  {(payload?.agent_name ?? 'C')[0]}
                </div>
                <span className="text-[11px] font-semibold text-ask-secondary">
                  {payload?.agent_name ?? 'Claude Code'}
                </span>
              </div>
              {payload?.is_working ? (
                <div className="flex flex-col gap-1.5 pl-0.5">
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
                </div>
              ) : (
                <span className="text-xs text-ask-secondary">Session started</span>
              )}
            </div>
          )}
          <div ref={bottomRef} />
        </>
      )}
    </div>
  )

  // Shared pending confirmation + compose bar
  const composeArea = (
    <>
      {sessionBlock && payload?.pending_confirmation && (
        <PendingConfirmationBar
          title={payload.pending_confirmation.title}
          body={payload.pending_confirmation.body}
          options={payload.pending_confirmation.options}
          accentColor={accentColor}
          onRespond={val => handleApprove(val)}
        />
      )}
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
    </>
  )

  if (theme.isAndroid) {
    return (
      <div className="flex flex-col h-full" data-block-id={sessionBlock?.blockID} data-block-type="agent_session">
        <div
          className="flex items-center gap-3 px-4 pt-3 pb-3 border-b border-ask-sep flex-shrink-0"
          style={accentColor !== '#8E8E93' ? { borderBottomColor: `${accentColor}30` } : undefined}
        >
          {androidNavBar}
        </div>
        {payload?.is_working && payload.last_message && (
          <LastMessageBar message={payload.last_message} color={accentColor} />
        )}
        <div className="flex-1 overflow-y-auto no-scrollbar">
          {chatHistory}
        </div>
        {composeArea}
      </div>
    )
  }

  // iOS — glass nav bar + floating glass compose bar
  const pillBg = isLight ? 'rgba(255,255,255,0.92)' : 'rgba(28,28,30,0.92)'
  const pillBorder = isLight ? '1px solid rgba(0,0,0,0.10)' : '1px solid rgba(255,255,255,0.10)'
  const pillShadow = isLight
    ? '0 6px 24px rgba(0,0,0,0.12), 0 2px 8px rgba(0,0,0,0.06)'
    : '0 6px 24px rgba(0,0,0,0.5), 0 2px 8px rgba(0,0,0,0.3)'

  return (
    <div className="relative h-full" data-block-id={sessionBlock?.blockID} data-block-type="agent_session">
      {/* Inner scroll — covers full phone height; content scrolls behind the chrome above */}
      <div className="absolute inset-0 overflow-y-auto no-scrollbar">
        {/* pt-24 = 96px: clears status bar row (48px) + nav bar row (~48px) */}
        <div className="pt-24 pb-[100px]">
          {payload?.is_working && payload.last_message && (
            <LastMessageBar message={payload.last_message} color={accentColor} />
          )}
          {chatHistory}
        </div>
      </div>

      {/* ONE combined top chrome — status bar row + nav bar row as a single element.
          Single backdrop-filter = no seam between the two rows. */}
      <div
        className="absolute top-0 left-0 right-0 z-20"
        style={{
          ...iosNavChromeStyle(isLight),
          ...(accentColor !== '#8E8E93' ? {
            background: `linear-gradient(${accentColor}20, ${accentColor}20), ${isLight ? 'rgba(242,242,247,0.38)' : 'rgba(28,28,30,0.38)'}`,
          } : {}),
        }}
      >
        <IOSStatusBarRow />
        <div className="flex items-center gap-3 px-4 pb-3">
          {iosNavBar}
        </div>
      </div>

      {/* Floating glass compose bar */}
      {sessionBlock && (
        <div className="absolute bottom-0 left-0 right-0 px-4 pb-6 flex flex-col gap-2 z-10">
          {payload?.pending_confirmation && (
            <div
              className="rounded-2xl overflow-hidden"
              style={{ background: pillBg, backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', border: pillBorder, boxShadow: pillShadow }}
            >
              <PendingConfirmationBar
                title={payload.pending_confirmation.title}
                body={payload.pending_confirmation.body}
                options={payload.pending_confirmation.options}
                accentColor={accentColor}
                onRespond={val => handleApprove(val)}
              />
            </div>
          )}
          <div
            className="flex items-center gap-2 pl-4 pr-2 py-2"
            style={{ background: pillBg, backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', borderRadius: 24, border: pillBorder, boxShadow: pillShadow }}
          >
            <input
              type="text"
              value={reply}
              onChange={e => setReply(e.target.value)}
              placeholder={payload?.placeholder ?? 'Message Claude…'}
              disabled={sending}
              onKeyDown={e => { if (e.key === 'Enter') handleSend(reply) }}
              className="flex-1 bg-transparent outline-none text-[15px] text-ask-text placeholder-ask-secondary/50 disabled:opacity-50"
            />
            {(reply.trim() || sending) && (
              <button
                onClick={() => handleSend(reply)}
                disabled={sending}
                className="w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0 transition-all"
                style={{ backgroundColor: '#007AFF' }}
              >
                {sending
                  ? <span className="text-white text-xs font-semibold">…</span>
                  : <svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M8 13V3M8 3L3.5 7.5M8 3L12.5 7.5" stroke="white" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/></svg>
                }
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
