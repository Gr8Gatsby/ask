import { useState, useEffect, useRef } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { getTaskMessages, getTasks } from '../lib/api'
import type { AskTask, TaskMessage } from '../lib/types'
import Markdown from '../components/shared/Markdown'

// ---- Message part types (Anthropic API content blocks) ----

interface TextPart       { type: 'text'; text: string }
interface ImagePart      { type: 'image'; source: { type: 'base64'; media_type: string; data: string } | { type: 'url'; url: string } }
interface DocumentPart   { type: 'document'; source: { type: 'base64'; media_type: string; data: string; filename?: string } | { type: 'url'; url: string; filename?: string } }
interface ToolUsePart    { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
interface ToolResultPart { type: 'tool_result'; tool_use_id: string; content: string | Array<{ type: string; text?: string }> }
interface ThinkingPart   { type: 'thinking'; thinking: string }

type MessagePart = TextPart | ImagePart | DocumentPart | ToolUsePart | ToolResultPart | ThinkingPart | { type: string }

// ---- Part renderers ----

function ToolUseCard({ part }: { part: ToolUsePart }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="rounded-lg border border-ask-sep bg-ask-card2/50 overflow-hidden text-xs">
      <button
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-ask-text/[0.05] transition-colors"
      >
        <span className="text-[10px] font-mono bg-ask-card px-1.5 py-0.5 rounded text-ask-blue border border-ask-sep">
          {part.name}
        </span>
        <span className="text-ask-secondary flex-1 truncate">tool call</span>
        <span className="text-ask-secondary text-[10px]">{open ? '▾' : '▸'}</span>
      </button>
      {open && (
        <pre className="px-3 pb-2 text-[10px] font-mono text-ask-secondary overflow-x-auto whitespace-pre-wrap break-all">
          {JSON.stringify(part.input, null, 2)}
        </pre>
      )}
    </div>
  )
}

function ToolResultCard({ part }: { part: ToolResultPart }) {
  const [open, setOpen] = useState(false)
  const text = typeof part.content === 'string'
    ? part.content
    : part.content.map(c => c.text ?? '').join('\n')
  const preview = text.split('\n').slice(0, 2).join('\n')
  const truncated = text.split('\n').length > 2 || text.length > 120

  return (
    <div className="rounded-lg border border-ask-sep bg-ask-card2/30 overflow-hidden text-xs">
      <button
        onClick={() => truncated && setOpen(o => !o)}
        className={`w-full flex items-center gap-2 px-3 py-2 text-left ${truncated ? 'hover:bg-ask-text/[0.05] transition-colors cursor-pointer' : 'cursor-default'}`}
      >
        <span className="text-[10px] font-mono bg-ask-card px-1.5 py-0.5 rounded text-ask-green border border-ask-sep">result</span>
        <span className="text-ask-secondary flex-1 truncate font-mono">{preview}</span>
        {truncated && <span className="text-ask-secondary text-[10px]">{open ? '▾' : '▸'}</span>}
      </button>
      {open && (
        <pre className="px-3 pb-2 text-[10px] font-mono text-ask-secondary overflow-x-auto whitespace-pre-wrap break-all border-t border-ask-sep pt-2">
          {text}
        </pre>
      )}
    </div>
  )
}

function ImageCard({ part }: { part: ImagePart }) {
  const src = part.source.type === 'url'
    ? part.source.url
    : `data:${part.source.media_type};base64,${part.source.data}`
  return (
    <img
      src={src}
      alt="Attached image"
      className="rounded-lg max-w-full border border-ask-sep"
    />
  )
}

function DocumentCard({ part }: { part: DocumentPart }) {
  const filename = part.source.type === 'url'
    ? (part.source.filename ?? part.source.url.split('/').pop() ?? 'document')
    : (part.source.filename ?? 'document')
  const mediaType = part.source.type === 'base64' ? part.source.media_type : ''
  const ext = filename.split('.').pop()?.toUpperCase() ?? mediaType.split('/').pop()?.toUpperCase() ?? 'FILE'
  return (
    <div className="flex items-center gap-3 rounded-lg border border-ask-sep bg-ask-card px-3 py-2.5">
      <div className="w-8 h-8 rounded bg-ask-card2 flex items-center justify-center text-[9px] font-bold text-ask-secondary flex-shrink-0">
        {ext}
      </div>
      <span className="text-xs text-ask-text truncate">{filename}</span>
    </div>
  )
}

function ThinkingCard({ part }: { part: ThinkingPart }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="rounded-lg border border-ask-sep bg-ask-card2/20 overflow-hidden text-xs italic">
      <button
        onClick={() => setOpen(o => !o)}
        className="w-full flex items-center gap-2 px-3 py-2 text-left hover:bg-ask-text/[0.05] transition-colors"
      >
        <span className="text-ask-secondary/70">thinking…</span>
        <span className="text-ask-secondary text-[10px] ml-auto">{open ? '▾' : '▸'}</span>
      </button>
      {open && (
        <p className="px-3 pb-2 text-[10px] text-ask-secondary/70 whitespace-pre-wrap border-t border-ask-sep pt-2">
          {part.thinking}
        </p>
      )}
    </div>
  )
}

// ---- Screen ----

export default function TaskThreadScreen() {
  const { taskID } = useParams<{ taskID: string }>()
  const navigate = useNavigate()
  const [task, setTask] = useState<AskTask | null>(null)
  const [messages, setMessages] = useState<TaskMessage[]>([])
  const [loading, setLoading] = useState(true)
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!taskID) return
    Promise.all([getTasks(), getTaskMessages(taskID)]).then(([tasks, msgs]) => {
      setTask(tasks.find(t => t.taskID === taskID) ?? null)
      setMessages(msgs)
      setLoading(false)
    })
  }, [taskID])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center gap-3 px-4 pt-3 pb-3 border-b border-ask-sep flex-shrink-0">
        <button onClick={() => navigate(-1)} className="text-ask-blue text-sm">‹ Back</button>
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-ask-text truncate">{task?.title ?? 'Task'}</p>
          <p className="text-[10px] text-ask-secondary">{task?.scriptName}</p>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar px-4 py-3 flex flex-col gap-3">
        {loading ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Loading...</div>
        ) : (
          messages.map(msg => {
            let parts: MessagePart[] = []
            try { parts = JSON.parse(msg.partsJSON) } catch { /* */ }

            return (
              <div key={msg.messageID} className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}>
                <div className={`max-w-[85%] flex flex-col gap-1.5 ${msg.role === 'user' ? 'items-end' : 'items-start'}`}>
                  {parts.map((part, i) => {
                    // Images and documents render full-width outside bubble
                    if (part.type === 'image') return <ImageCard key={i} part={part as ImagePart} />
                    if (part.type === 'document') return <DocumentCard key={i} part={part as DocumentPart} />
                    if (part.type === 'tool_use') return <ToolUseCard key={i} part={part as ToolUsePart} />
                    if (part.type === 'tool_result') return <ToolResultCard key={i} part={part as ToolResultPart} />
                    if (part.type === 'thinking') return <ThinkingCard key={i} part={part as ThinkingPart} />

                    // Text in a bubble
                    if (part.type === 'text' && (part as TextPart).text) {
                      return (
                        <div
                          key={i}
                          className={`rounded-2xl px-3 py-2 ${
                            msg.role === 'user'
                              ? 'bg-ask-blue rounded-br-sm'
                              : 'bg-ask-card rounded-bl-sm'
                          }`}
                        >
                          <Markdown>{(part as TextPart).text}</Markdown>
                        </div>
                      )
                    }

                    return <span key={i} className="text-[10px] font-mono text-ask-secondary/50">[{part.type}]</span>
                  })}
                </div>
              </div>
            )
          })
        )}
        <div ref={bottomRef} />
      </div>
    </div>
  )
}
