import { useState, useEffect, useRef } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { getTaskMessages, getTasks, getTaskArtifacts, getArtifactContent } from '../lib/api'
import type { AskTask, TaskArtifact, TaskMessage } from '../lib/types'
import Markdown from '../components/shared/Markdown'
import { useTheme } from '../lib/PlatformContext'

// ---- Message part types (Anthropic API content blocks) ----

interface TextPart       { type: 'text'; text: string }
interface ImagePart      { type: 'image'; source: { type: 'base64'; media_type: string; data: string } | { type: 'url'; url: string } }
interface DocumentPart   { type: 'document'; source: { type: 'base64'; media_type: string; data: string; filename?: string } | { type: 'url'; url: string; filename?: string } }
interface ToolUsePart    { type: 'tool_use'; id: string; name: string; input: Record<string, unknown> }
interface ToolResultPart { type: 'tool_result'; tool_use_id: string; content: string | Array<{ type: string; text?: string; data?: string; media_type?: string; filename?: string; source?: unknown }> }
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

  // Content can be a plain string or an array of typed blocks
  if (typeof part.content === 'string') {
    const text = part.content
    const preview = text.split('\n').slice(0, 2).join('\n')
    const truncated = text.split('\n').length > 2 || text.length > 120
    return (
      <div className="rounded-lg border border-ask-sep bg-ask-card2/30 overflow-hidden text-xs">
        <button
          onClick={() => truncated && setOpen(o => !o)}
          className={`w-full flex items-center gap-2 px-3 py-2 text-left ${truncated ? 'hover:bg-ask-text/[0.05] cursor-pointer' : 'cursor-default'}`}
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

  // Array content — render each block (text, image, document)
  return (
    <div className="flex flex-col gap-1.5">
      {part.content.map((block, i) => {
        if (block.type === 'text' && block.text) {
          const text = block.text
          const preview = text.split('\n').slice(0, 2).join('\n')
          const truncated = text.split('\n').length > 2 || text.length > 120
          return (
            <div key={i} className="rounded-lg border border-ask-sep bg-ask-card2/30 overflow-hidden text-xs">
              <button
                onClick={() => truncated && setOpen(o => !o)}
                className={`w-full flex items-center gap-2 px-3 py-2 text-left ${truncated ? 'hover:bg-ask-text/[0.05] cursor-pointer' : 'cursor-default'}`}
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
        if (block.type === 'image' && block.data && block.media_type) {
          return (
            <img
              key={i}
              src={`data:${block.media_type};base64,${block.data}`}
              alt="Attached image"
              className="rounded-lg max-w-full border border-ask-sep"
            />
          )
        }
        if (block.type === 'document') {
          const filename = block.filename ?? 'document'
          const ext = filename.split('.').pop()?.toUpperCase() ?? (block.media_type?.split('/').pop()?.toUpperCase() ?? 'FILE')
          return (
            <div key={i} className="flex items-center gap-3 rounded-lg border border-ask-sep bg-ask-card px-3 py-2.5">
              <div className="w-8 h-8 rounded bg-ask-card2 flex items-center justify-center text-[9px] font-bold text-ask-secondary flex-shrink-0">
                {ext}
              </div>
              <span className="text-xs text-ask-text truncate">{filename}</span>
            </div>
          )
        }
        return null
      })}
    </div>
  )
}

function ImageCard({ part }: { part: ImagePart }) {
  const src = part.source.type === 'url'
    ? part.source.url
    : `data:${part.source.media_type};base64,${part.source.data}`
  return (
    <img src={src} alt="Attached image" className="rounded-lg max-w-full border border-ask-sep" />
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

// ---- Artifact file viewer sheet ----

function fileIcon(mimeType: string): string {
  if (mimeType.includes('markdown')) return 'description'
  if (mimeType.includes('image')) return 'image'
  if (mimeType.includes('pdf')) return 'picture_as_pdf'
  if (mimeType.includes('typescript') || mimeType.includes('javascript') || mimeType.includes('python')) return 'code'
  return 'description'
}

function fileExt(filename: string): string {
  return filename.split('.').pop()?.toUpperCase() ?? 'FILE'
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function isTextMime(mimeType: string): boolean {
  return mimeType.startsWith('text/') || mimeType.includes('json') || mimeType.includes('typescript') || mimeType.includes('javascript')
}

function isMarkdown(filename: string, mimeType: string): boolean {
  return filename.endsWith('.md') || mimeType.includes('markdown')
}

function ArtifactViewer({ artifact, onDismiss, isAndroid }: { artifact: TaskArtifact; onDismiss: () => void; isAndroid: boolean }) {
  const [content, setContent] = useState<string | null>(null)
  const [loadingContent, setLoadingContent] = useState(true)

  useEffect(() => {
    getArtifactContent(artifact.artifactID)
      .then(c => { setContent(c); setLoadingContent(false) })
      .catch(() => { setContent(null); setLoadingContent(false) })
  }, [artifact.artifactID])

  const showMarkdown = !loadingContent && content !== null && isMarkdown(artifact.filename, artifact.mimeType)
  const showCode = !loadingContent && content !== null && !showMarkdown && isTextMime(artifact.mimeType)

  return (
    <div className="absolute inset-0 z-50 flex flex-col" style={{ background: 'var(--color-ask-bg, #f2f2f7)' }}>
      {/* Header */}
      <div className={`flex items-center gap-3 px-4 pt-3 pb-3 flex-shrink-0 border-b border-ask-sep/50`}>
        <div className="flex-1 min-w-0">
          <p className={`${isAndroid ? 'text-sm font-semibold' : 'text-[17px] font-semibold'} text-ask-text truncate`}>
            {artifact.filename}
          </p>
          <p className="text-[12px] text-ask-secondary">{formatBytes(artifact.sizeBytes)}</p>
        </div>
        <button
          onClick={onDismiss}
          className={`flex-shrink-0 font-semibold ${isAndroid ? 'text-ask-blue text-sm' : 'text-ask-blue text-[17px]'}`}
        >
          Done
        </button>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto no-scrollbar">
        {loadingContent ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Loading…</div>
        ) : content === null ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Could not load file</div>
        ) : showMarkdown ? (
          <div className="px-4 py-4 text-[15px] text-ask-text">
            <Markdown>{content}</Markdown>
          </div>
        ) : showCode ? (
          <pre className="px-4 py-4 text-[12px] font-mono text-ask-text whitespace-pre-wrap break-all leading-relaxed">
            {content}
          </pre>
        ) : (
          <div className="flex flex-col items-center justify-center h-40 gap-2 text-ask-secondary">
            <span className="mat-icon" style={{ fontSize: 40 }}>description</span>
            <p className="text-sm">{fileExt(artifact.filename)} file</p>
          </div>
        )}
      </div>
    </div>
  )
}

// ---- Artifact card ----

function ArtifactCard({ artifact, onTap, isAndroid }: { artifact: TaskArtifact; onTap: () => void; isAndroid: boolean }) {
  return (
    <button
      onClick={onTap}
      className={`w-full flex items-center gap-3 rounded-xl border border-ask-sep bg-ask-card px-3.5 py-3 text-left active:opacity-70 transition-opacity`}
    >
      <div className={`flex items-center justify-center flex-shrink-0 ${isAndroid ? 'w-9 h-9 rounded-lg' : 'w-10 h-10 rounded-xl'} bg-ask-card2`}>
        <span className="mat-icon text-ask-secondary" style={{ fontSize: 20, fontVariationSettings: "'FILL' 0, 'wght' 400, 'opsz' 20" }}>
          {fileIcon(artifact.mimeType)}
        </span>
      </div>
      <div className="flex-1 min-w-0">
        <p className={`${isAndroid ? 'text-sm' : 'text-[15px]'} font-medium text-ask-text truncate`}>{artifact.filename}</p>
        <p className="text-[12px] text-ask-secondary">{formatBytes(artifact.sizeBytes)}</p>
      </div>
      <svg width="8" height="13" viewBox="0 0 8 13" fill="none" className="text-ask-secondary/50 flex-shrink-0">
        <path d="M1 1l6 5.5L1 12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    </button>
  )
}

function MessageBubble({ msg, isAndroid }: { msg: TaskMessage; isAndroid: boolean }) {
  let parts: MessagePart[] = []
  try { parts = JSON.parse(msg.partsJSON) } catch { /* */ }

  const isUser = msg.role === 'user'

  if (isUser) {
    // User messages: right-aligned bubble
    return (
      <div className="flex justify-end px-4">
        <div className="max-w-[80%] flex flex-col gap-1.5 items-end">
          {parts.map((part, i) => {
            if (part.type === 'image') return <ImageCard key={i} part={part as ImagePart} />
            if (part.type === 'document') return <DocumentCard key={i} part={part as DocumentPart} />
            if (part.type === 'text' && (part as TextPart).text) {
              return isAndroid ? (
                <div key={i} className="rounded-2xl rounded-br-sm px-3.5 py-2 bg-ask-blue">
                  <Markdown className="text-white">{(part as TextPart).text}</Markdown>
                </div>
              ) : (
                <div key={i} className="px-3.5 py-2.5 text-[15px] leading-snug bg-ask-blue text-white rounded-[20px] rounded-br-[5px]">
                  <Markdown>{(part as TextPart).text}</Markdown>
                </div>
              )
            }
            return null
          })}
        </div>
      </div>
    )
  }

  // Assistant messages: full-width, no bubble
  return (
    <div className="flex flex-col gap-2 px-4">
      {parts.map((part, i) => {
        if (part.type === 'image') return <ImageCard key={i} part={part as ImagePart} />
        if (part.type === 'document') return <DocumentCard key={i} part={part as DocumentPart} />
        if (part.type === 'tool_use') return <ToolUseCard key={i} part={part as ToolUsePart} />
        if (part.type === 'tool_result') return <ToolResultCard key={i} part={part as ToolResultPart} />
        if (part.type === 'thinking') return <ThinkingCard key={i} part={part as ThinkingPart} />
        if (part.type === 'text' && (part as TextPart).text) {
          return (
            <div key={i} className={`text-ask-text ${isAndroid ? 'text-sm' : 'text-[15px]'} leading-relaxed`}>
              <Markdown>{(part as TextPart).text}</Markdown>
            </div>
          )
        }
        return <span key={i} className="text-[10px] font-mono text-ask-secondary/50">[{part.type}]</span>
      })}
    </div>
  )
}

// ---- Screen ----

export default function TaskThreadScreen() {
  const { taskID } = useParams<{ taskID: string }>()
  const navigate = useNavigate()
  const theme = useTheme()
  const [task, setTask] = useState<AskTask | null>(null)
  const [messages, setMessages] = useState<TaskMessage[]>([])
  const [artifacts, setArtifacts] = useState<TaskArtifact[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(false)
  const [viewingArtifact, setViewingArtifact] = useState<TaskArtifact | null>(null)
  const bottomRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!taskID) return
    Promise.all([
      getTasks(),
      getTaskMessages(taskID),
      getTaskArtifacts(taskID),
    ])
      .then(([tasks, msgs, arts]) => {
        setTask(tasks.find(t => t.taskID === taskID) ?? null)
        setMessages(msgs)
        setArtifacts(arts)
        setLoading(false)
      })
      .catch(() => { setLoading(false); setError(true) })
  }, [taskID])

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ behavior: 'smooth' })
  }, [messages])

  return (
    <div className="flex flex-col h-full relative">
      {/* Nav bar */}
      <div className={`flex items-center gap-3 px-4 pt-3 pb-3 flex-shrink-0 ${theme.isAndroid ? 'border-b border-ask-sep' : 'border-b border-ask-sep/50'}`}>
        <button onClick={() => navigate(-1)} className={theme.navBackClass}>
          {theme.navBackIcon}
          {!theme.isAndroid && <span>Feed</span>}
        </button>
        <div className="flex-1 min-w-0">
          {theme.isAndroid ? (
            <>
              <p className="text-sm font-semibold text-ask-text truncate">{task?.title ?? 'Task'}</p>
              <p className="text-[10px] text-ask-secondary">{task?.scriptName}</p>
            </>
          ) : (
            <p className={`${theme.typeTitleMedium} text-ask-text truncate`}>{task?.title ?? 'Task'}</p>
          )}
        </div>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar py-3 flex flex-col gap-1">
        {loading ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Loading…</div>
        ) : error ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Failed to load messages</div>
        ) : (
          <>
            {messages.map(msg => (
              <MessageBubble key={msg.messageID} msg={msg} isAndroid={theme.isAndroid} />
            ))}

            {/* Artifact cards */}
            {artifacts.length > 0 && (
              <div className={`flex flex-col gap-2 px-4 ${messages.length > 0 ? 'mt-3 pt-3 border-t border-ask-sep/30' : ''}`}>
                {messages.length === 0 && (
                  <p className="text-[12px] text-ask-secondary text-center mb-1">
                    No conversation history — task ran autonomously
                  </p>
                )}
                {artifacts.map(art => (
                  <ArtifactCard key={art.artifactID} artifact={art} onTap={() => setViewingArtifact(art)} isAndroid={theme.isAndroid} />
                ))}
              </div>
            )}

            {messages.length === 0 && artifacts.length === 0 && (
              <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No messages</div>
            )}
          </>
        )}
        <div ref={bottomRef} />
      </div>

      {/* File viewer */}
      {viewingArtifact && (
        <ArtifactViewer
          artifact={viewingArtifact}
          onDismiss={() => setViewingArtifact(null)}
          isAndroid={theme.isAndroid}
        />
      )}
    </div>
  )
}
