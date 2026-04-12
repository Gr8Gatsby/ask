import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { getTasks } from '../lib/api'
import type { AskTask } from '../lib/types'

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime()
  const m = Math.floor(diff / 60_000)
  if (m < 1) return 'just now'
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ago`
  return `${Math.floor(h / 24)}d ago`
}

function StatusBadge({ status }: { status: AskTask['status'] }) {
  if (status === 'input-required') {
    return (
      <span className="text-[10px] font-semibold bg-ask-orange/20 text-ask-orange px-1.5 py-0.5 rounded-full flex-shrink-0">
        Needs input
      </span>
    )
  }
  if (status === 'working') {
    return (
      <span className="flex items-center gap-1 flex-shrink-0">
        <span className="w-1.5 h-1.5 rounded-full bg-ask-blue animate-pulse" />
        <span className="text-[10px] text-ask-blue">Working</span>
      </span>
    )
  }
  if (status === 'failed') {
    return <span className="text-[10px] text-ask-red flex-shrink-0">Failed</span>
  }
  if (status === 'cancelled') {
    return <span className="text-[10px] text-ask-secondary flex-shrink-0">Cancelled</span>
  }
  return <span className="text-[10px] text-ask-green flex-shrink-0">Done</span>
}

function TaskRow({ task, onClick }: { task: AskTask; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-start gap-3 px-4 py-3.5 hover:bg-ask-text/[0.05] transition-colors text-left border-b border-ask-sep"
    >
      <div className="flex-1 min-w-0">
        <div className="flex items-start justify-between gap-2 mb-0.5">
          <p className="text-sm text-ask-text font-medium leading-snug">{task.title}</p>
          <span className="text-[10px] text-ask-secondary flex-shrink-0 mt-0.5">{relativeTime(task.lastActivityAt)}</span>
        </div>
        <div className="flex items-center gap-2">
          <p className="text-xs text-ask-secondary truncate">{task.scriptName}</p>
          <span className="text-ask-secondary/40">·</span>
          <StatusBadge status={task.status} />
        </div>
      </div>
      <span className="text-ask-secondary mt-0.5 flex-shrink-0">›</span>
    </button>
  )
}

export default function TaskFeedScreen() {
  const [tasks, setTasks] = useState<AskTask[]>([])
  const [loading, setLoading] = useState(true)
  const navigate = useNavigate()

  const load = useCallback(() => {
    getTasks().then(t => { setTasks(t); setLoading(false) })
  }, [])

  useEffect(() => {
    load()
    const id = setInterval(load, 15_000)
    return () => clearInterval(id)
  }, [load])

  const active = tasks
    .filter(t => t.status === 'working' || t.status === 'input-required')
    .sort((a, b) => {
      if (a.status === 'input-required' && b.status !== 'input-required') return -1
      if (b.status === 'input-required' && a.status !== 'input-required') return 1
      return new Date(b.lastActivityAt).getTime() - new Date(a.lastActivityAt).getTime()
    })

  const recent = tasks
    .filter(t => t.status !== 'working' && t.status !== 'input-required')
    .sort((a, b) => new Date(b.lastActivityAt).getTime() - new Date(a.lastActivityAt).getTime())

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 pt-3 pb-3 border-b border-ask-sep flex-shrink-0">
        <h1 className="text-xl font-bold text-ask-text">Feed</h1>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar">
        {loading ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Loading…</div>
        ) : tasks.length === 0 ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No tasks</div>
        ) : (
          <>
            {active.length > 0 && (
              <section>
                <p className="px-4 pt-4 pb-1 text-xs font-semibold text-ask-secondary uppercase tracking-wide">Active</p>
                {active.map(t => (
                  <TaskRow key={t.taskID} task={t} onClick={() => navigate(`/tasks/${t.taskID}`)} />
                ))}
              </section>
            )}
            {recent.length > 0 && (
              <section>
                {active.length > 0 && (
                  <p className="px-4 pt-4 pb-1 text-xs font-semibold text-ask-secondary uppercase tracking-wide">Recent</p>
                )}
                {recent.map(t => (
                  <TaskRow key={t.taskID} task={t} onClick={() => navigate(`/tasks/${t.taskID}`)} />
                ))}
              </section>
            )}
          </>
        )}
      </div>
    </div>
  )
}
