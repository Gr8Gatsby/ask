import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { getTasks } from '../lib/api'
import type { AskTask, Block, AgentSessionPayload, FeedItemPayload, CompactSummaryPayload } from '../lib/types'
import { usePlatform } from '../lib/PlatformContext'
import { useBlocks } from '../lib/useBlocks'
import ScriptIcon from '../components/shared/ScriptIcon'

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime()
  const m = Math.floor(diff / 60_000)
  if (m < 1) return 'just now'
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ago`
  return `${Math.floor(h / 24)}d ago`
}

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

// ---- Active session row (from agent_session blocks) ----

function sessionStatus(payload: AgentSessionPayload): { label: string; color: string; pulse: boolean } {
  if (payload.pending_confirmation) return { label: 'Needs Input', color: 'text-ask-orange', pulse: false }
  if (payload.is_working) return { label: 'Working', color: 'text-ask-blue', pulse: true }
  return { label: 'Idle', color: 'text-ask-secondary', pulse: false }
}

// ---- iOS ----

function IOSSessionRow({ block, payload, onClick, first, last }: {
  block: Block; payload: AgentSessionPayload; onClick: () => void; first: boolean; last: boolean
}) {
  const borderT = first ? '' : 'border-t border-ask-sep/40'
  const roundT = first ? 'rounded-t-xl' : ''
  const roundB = last ? 'rounded-b-xl' : ''
  const { label, color, pulse } = sessionStatus(payload)

  return (
    <button
      data-block-id={block.blockID}
      data-block-type="agent_session"
      onClick={onClick}
      className={`w-full flex items-center gap-3 min-h-[56px] px-4 py-3 bg-ask-card text-left active:opacity-70 transition-opacity ${borderT} ${roundT} ${roundB}`}
    >
      <div className="flex-1 min-w-0">
        <p className="text-[17px] text-ask-text leading-snug truncate">{payload.project}</p>
        <p className="text-[13px] text-ask-secondary truncate">{block.scriptName}</p>
      </div>
      <div className="flex items-center gap-2 flex-shrink-0">
        <span className={`flex items-center gap-1.5 ${color}`}>
          {pulse && <span className="w-1.5 h-1.5 rounded-full bg-ask-blue animate-pulse" />}
          <span className="text-[13px]">{label}</span>
        </span>
        <svg width="8" height="13" viewBox="0 0 8 13" fill="none" className="text-ask-secondary/50 flex-shrink-0">
          <path d="M1 1l6 5.5L1 12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
    </button>
  )
}

function IOSTaskRow({ task, onClick, first, last }: { task: AskTask; onClick: () => void; first: boolean; last: boolean }) {
  const borderT = first ? '' : 'border-t border-ask-sep/40'
  const roundT = first ? 'rounded-t-xl' : ''
  const roundB = last ? 'rounded-b-xl' : ''
  return (
    <button
      onClick={onClick}
      className={`w-full flex items-center gap-3 min-h-[56px] px-4 py-3 bg-ask-card text-left active:opacity-70 transition-opacity ${borderT} ${roundT} ${roundB}`}
    >
      <div className="flex-1 min-w-0">
        <p className="text-[17px] text-ask-text leading-snug truncate">{task.title}</p>
        <div className="flex items-center gap-1.5 mt-0.5">
          <span className="text-[13px] text-ask-secondary truncate">{task.scriptName}</span>
          {task.artifactCount > 0 && (
            <>
              <span className="text-ask-secondary/40 text-[11px]">·</span>
              <span className="text-[13px] text-ask-secondary flex-shrink-0">
                {task.artifactCount} {task.artifactCount === 1 ? 'file' : 'files'}
              </span>
            </>
          )}
        </div>
      </div>
      <div className="flex items-center gap-2 flex-shrink-0">
        <span className="text-[13px] text-ask-secondary">Done</span>
        <svg width="8" height="13" viewBox="0 0 8 13" fill="none" className="text-ask-secondary/50 flex-shrink-0">
          <path d="M1 1l6 5.5L1 12" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
      </div>
    </button>
  )
}

function IOSActivityRow({ block, first, last }: { block: Block; first: boolean; last: boolean }) {
  const borderT = first ? '' : 'border-t border-ask-sep/40'
  const roundT = first ? 'rounded-t-xl' : ''
  const roundB = last ? 'rounded-b-xl' : ''

  let title = block.scriptName
  let body: string | undefined
  let timestamp = block.createdAt
  let fileCount = 0

  if (block.blockType === 'feed_item') {
    const p = parsePayload<FeedItemPayload>(block.payload)
    if (p) { title = p.title; body = p.body; timestamp = p.timestamp ?? timestamp }
  } else if (block.blockType === 'compact_summary') {
    const p = parsePayload<CompactSummaryPayload>(block.payload)
    if (p) { title = p.project; body = p.summary }
  }

  return (
    <div data-block-id={block.blockID} data-block-type={block.blockType} className={`flex items-center gap-3 min-h-[56px] px-4 py-3 bg-ask-card ${borderT} ${roundT} ${roundB}`}>
      <div className="w-8 h-8 rounded-full bg-ask-green/20 flex items-center justify-center flex-shrink-0">
        <span className="mat-icon text-ask-green" style={{ fontSize: 16, fontVariationSettings: "'FILL' 1" }}>check_circle</span>
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-[17px] text-ask-text leading-snug truncate">{title}</p>
        <div className="flex items-center gap-1.5 mt-0.5">
          <span className="text-[13px] text-ask-secondary truncate">{block.scriptName}</span>
          {fileCount > 0 && (
            <>
              <span className="text-ask-secondary/40 text-[11px]">·</span>
              <span className="text-[13px] text-ask-secondary flex-shrink-0">{fileCount} {fileCount === 1 ? 'file' : 'files'}</span>
            </>
          )}
        </div>
        {body && <p className="text-[12px] text-ask-secondary/70 line-clamp-1 mt-0.5">{body}</p>}
      </div>
      <span className="text-[13px] text-ask-secondary/60 flex-shrink-0 ml-2">{relativeTime(timestamp)}</span>
    </div>
  )
}

function IOSFeedScreen({ sessions, recentTasks, activityBlocks, onNavigateSession, onNavigateTask }: {
  sessions: Array<{ block: Block; payload: AgentSessionPayload }>
  recentTasks: AskTask[]
  activityBlocks: Block[]
  onNavigateSession: (block: Block, payload: AgentSessionPayload) => void
  onNavigateTask: (taskID: string) => void
}) {
  const totalRecent = recentTasks.length + activityBlocks.length
  return (
    <div className="flex flex-col h-full overflow-y-auto no-scrollbar bg-ask-bg">
      <div className="px-4 pt-3 pb-2">
        <h1 className="text-[34px] font-bold text-ask-text leading-tight">Feed</h1>
      </div>

      {sessions.length > 0 && (
        <>
          <p className="text-[13px] text-ask-secondary uppercase tracking-wide px-4 pb-1 pt-3">Active</p>
          <div className="mx-4">
            {sessions.map(({ block, payload }, i) => (
              <IOSSessionRow
                key={block.blockID} block={block} payload={payload}
                onClick={() => onNavigateSession(block, payload)}
                first={i === 0} last={i === sessions.length - 1}
              />
            ))}
          </div>
        </>
      )}

      {totalRecent > 0 && (
        <>
          <p className="text-[13px] text-ask-secondary uppercase tracking-wide px-4 pb-1 pt-5">Recent</p>
          <div className="mx-4">
            {recentTasks.map((t, i) => (
              <IOSTaskRow
                key={t.taskID} task={t} onClick={() => onNavigateTask(t.taskID)}
                first={i === 0} last={i === recentTasks.length - 1 && activityBlocks.length === 0}
              />
            ))}
            {activityBlocks.map((b, i) => (
              <IOSActivityRow
                key={b.blockID} block={b}
                first={recentTasks.length === 0 && i === 0}
                last={i === activityBlocks.length - 1}
              />
            ))}
          </div>
        </>
      )}

      <div className="h-6" />
    </div>
  )
}

// ---- Android ----

function AndroidSessionRow({ block, payload, onClick, last = false }: {
  block: Block; payload: AgentSessionPayload; onClick: () => void; last?: boolean
}) {
  const { label, color, pulse } = sessionStatus(payload)
  return (
    <button
      data-block-id={block.blockID}
      data-block-type="agent_session"
      onClick={onClick}
      className={`w-full flex items-start gap-3 px-4 py-3.5 hover:bg-ask-text/[0.05] transition-colors text-left ${last ? '' : 'border-b border-ask-sep'}`}
    >
      {block.scriptIconSVG ? (
        <div className="w-9 h-9 rounded-lg overflow-hidden flex-shrink-0 bg-ask-card2 mt-0.5">
          <ScriptIcon scriptIconSVG={block.scriptIconSVG} scriptName={block.scriptName} size={36} />
        </div>
      ) : (
        <div className="w-9 h-9 rounded-lg bg-ask-card2 flex items-center justify-center flex-shrink-0 mt-0.5">
          <span className="text-[11px] font-bold text-ask-secondary">{block.scriptName[0]}</span>
        </div>
      )}
      <div className="flex-1 min-w-0">
        <div className="flex items-start justify-between gap-2 mb-0.5">
          <p className="text-sm text-ask-text font-semibold leading-snug truncate">{payload.project}</p>
        </div>
        <div className="flex items-center gap-1.5">
          <p className="text-xs text-ask-secondary truncate">{block.scriptName}</p>
          <span className="text-ask-secondary/40 text-[10px]">·</span>
          <span className={`flex items-center gap-1 text-xs ${color}`}>
            {pulse && <span className="w-1.5 h-1.5 rounded-full bg-ask-blue animate-pulse" />}
            {label}
          </span>
        </div>
      </div>
      <span className="text-ask-secondary mt-0.5 flex-shrink-0">›</span>
    </button>
  )
}

function AndroidTaskRow({ task, onClick, last = false }: { task: AskTask; onClick: () => void; last?: boolean }) {
  return (
    <button
      onClick={onClick}
      className={`w-full flex items-start gap-3 px-4 py-3.5 hover:bg-ask-text/[0.05] transition-colors text-left ${last ? '' : 'border-b border-ask-sep'}`}
    >
      <div className="w-9 h-9 rounded-full bg-ask-green/20 flex items-center justify-center flex-shrink-0 mt-0.5">
        <span className="mat-icon text-ask-green" style={{ fontSize: 18, fontVariationSettings: "'FILL' 1" }}>check_circle</span>
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-start justify-between gap-2 mb-0.5">
          <p className="text-sm text-ask-text font-medium leading-snug">{task.title}</p>
          <span className="text-[10px] text-ask-secondary flex-shrink-0 mt-0.5">{relativeTime(task.lastActivityAt)}</span>
        </div>
        <div className="flex items-center gap-1.5">
          <p className="text-xs text-ask-secondary truncate">{task.scriptName}</p>
          {task.artifactCount > 0 && (
            <>
              <span className="text-ask-secondary/40 text-[10px]">·</span>
              <span className="mat-icon text-ask-secondary/60" style={{ fontSize: 12 }}>attach_file</span>
              <span className="text-[10px] text-ask-secondary">{task.artifactCount}</span>
            </>
          )}
        </div>
      </div>
    </button>
  )
}

function AndroidActivityRow({ block, last = false }: { block: Block; last?: boolean }) {
  let title = block.scriptName
  let body: string | undefined
  let timestamp = block.createdAt

  if (block.blockType === 'feed_item') {
    const p = parsePayload<FeedItemPayload>(block.payload)
    if (p) { title = p.title; body = p.body; timestamp = p.timestamp ?? timestamp }
  } else if (block.blockType === 'compact_summary') {
    const p = parsePayload<CompactSummaryPayload>(block.payload)
    if (p) { title = p.project; body = p.summary }
  }

  return (
    <div data-block-id={block.blockID} data-block-type={block.blockType} className={`flex items-start gap-3 px-4 py-3.5 ${last ? '' : 'border-b border-ask-sep'}`}>
      {block.scriptIconSVG ? (
        <div className="w-9 h-9 rounded-lg overflow-hidden flex-shrink-0 bg-ask-card2 mt-0.5">
          <ScriptIcon scriptIconSVG={block.scriptIconSVG} scriptName={block.scriptName} size={36} />
        </div>
      ) : (
        <div className="w-9 h-9 rounded-full bg-ask-green/20 flex items-center justify-center flex-shrink-0 mt-0.5">
          <span className="mat-icon text-ask-green" style={{ fontSize: 18, fontVariationSettings: "'FILL' 1" }}>check_circle</span>
        </div>
      )}
      <div className="flex-1 min-w-0">
        <div className="flex items-start justify-between gap-2 mb-0.5">
          <p className="text-sm text-ask-text font-medium leading-snug truncate">{title}</p>
          <span className="text-[10px] text-ask-secondary flex-shrink-0 mt-0.5">{relativeTime(timestamp)}</span>
        </div>
        {body && <p className="text-xs text-ask-secondary line-clamp-2 leading-snug">{body}</p>}
        <p className="text-[10px] text-ask-secondary/70 mt-0.5">{block.scriptName}</p>
      </div>
    </div>
  )
}

function AndroidFeedScreen({ sessions, recentTasks, activityBlocks, onNavigateSession, onNavigateTask }: {
  sessions: Array<{ block: Block; payload: AgentSessionPayload }>
  recentTasks: AskTask[]
  activityBlocks: Block[]
  onNavigateSession: (block: Block, payload: AgentSessionPayload) => void
  onNavigateTask: (taskID: string) => void
}) {
  const totalRecent = recentTasks.length + activityBlocks.length
  return (
    <div className="flex flex-col h-full">
      <div className="px-4 pt-4 pb-3 flex-shrink-0">
        <h1 className="text-[28px] font-medium text-ask-text leading-tight">Feed</h1>
      </div>
      <div className="flex-1 overflow-y-auto no-scrollbar">
        {sessions.length > 0 && (
          <section>
            <p className="px-4 pt-3 pb-1 text-xs font-semibold text-ask-secondary uppercase tracking-wide">Active</p>
            {sessions.map(({ block, payload }, i) => (
              <AndroidSessionRow
                key={block.blockID} block={block} payload={payload}
                onClick={() => onNavigateSession(block, payload)}
                last={i === sessions.length - 1 && totalRecent === 0}
              />
            ))}
          </section>
        )}
        {totalRecent > 0 && (
          <section>
            {sessions.length > 0 && <p className="px-4 pt-4 pb-1 text-xs font-semibold text-ask-secondary uppercase tracking-wide">Recent</p>}
            {recentTasks.map((t, i) => (
              <AndroidTaskRow
                key={t.taskID} task={t} onClick={() => onNavigateTask(t.taskID)}
                last={i === recentTasks.length - 1 && activityBlocks.length === 0}
              />
            ))}
            {activityBlocks.map((b, i) => (
              <AndroidActivityRow key={b.blockID} block={b} last={i === activityBlocks.length - 1} />
            ))}
          </section>
        )}
      </div>
    </div>
  )
}

// ---- Screen ----

const ACTIVITY_BLOCK_TYPES = new Set(['feed_item', 'compact_summary'])

export default function TaskFeedScreen() {
  const [tasks, setTasks] = useState<AskTask[]>([])
  const navigate = useNavigate()
  const { platform } = usePlatform()
  const isAndroid = platform === 'android'
  const { blocks } = useBlocks()

  const load = useCallback(() => {
    getTasks().then(t => setTasks(t)).catch(() => {})
  }, [])

  useEffect(() => {
    load()
    const id = setInterval(load, 15_000)
    return () => clearInterval(id)
  }, [load])

  // Active sessions from agent_session blocks — the ground truth for what's running
  const sessions = blocks
    .filter(b => b.blockType === 'agent_session')
    .map(b => ({ block: b, payload: parsePayload<AgentSessionPayload>(b.payload) }))
    .filter((s): s is { block: Block; payload: AgentSessionPayload } => s.payload !== null)
    .sort((a, b) => {
      // input-required first, then working, then idle
      const priority = (p: AgentSessionPayload) =>
        p.pending_confirmation ? 0 : p.is_working ? 1 : 2
      return priority(a.payload) - priority(b.payload)
    })

  // Recent completed tasks from the tasks API
  const recentTasks = tasks
    .filter(t => t.status !== 'working' && t.status !== 'input-required')
    .sort((a, b) => new Date(b.lastActivityAt).getTime() - new Date(a.lastActivityAt).getTime())

  // Activity blocks (feed_item, compact_summary) sorted by time
  const activityBlocks = blocks
    .filter(b => ACTIVITY_BLOCK_TYPES.has(b.blockType))
    .sort((a, b) => {
      const aTime = (parsePayload<FeedItemPayload>(a.payload)?.timestamp) ?? a.createdAt
      const bTime = (parsePayload<FeedItemPayload>(b.payload)?.timestamp) ?? b.createdAt
      return new Date(bTime).getTime() - new Date(aTime).getTime()
    })

  function handleNavigateSession(block: Block, payload: AgentSessionPayload) {
    if (payload.task_id) {
      navigate(`/tasks/${payload.task_id}`)
    } else {
      navigate(`/session/${block.scriptID}/${payload.session_id}`)
    }
  }

  if (sessions.length === 0 && recentTasks.length === 0 && activityBlocks.length === 0) {
    return (
      <div className="flex flex-col h-full">
        {isAndroid
          ? <div className="px-4 pt-4 pb-3 flex-shrink-0"><h1 className="text-[28px] font-medium text-ask-text leading-tight">Feed</h1></div>
          : <div className="px-4 pt-3 pb-2"><h1 className="text-[34px] font-bold text-ask-text leading-tight">Feed</h1></div>
        }
        <div className="flex items-center justify-center flex-1 text-ask-secondary text-sm">No activity yet</div>
      </div>
    )
  }

  if (isAndroid) {
    return (
      <AndroidFeedScreen
        sessions={sessions} recentTasks={recentTasks} activityBlocks={activityBlocks}
        onNavigateSession={handleNavigateSession} onNavigateTask={id => navigate(`/tasks/${id}`)}
      />
    )
  }
  return (
    <IOSFeedScreen
      sessions={sessions} recentTasks={recentTasks} activityBlocks={activityBlocks}
      onNavigateSession={handleNavigateSession} onNavigateTask={id => navigate(`/tasks/${id}`)}
    />
  )
}
