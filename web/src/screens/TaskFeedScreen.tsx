import { useState, useEffect } from 'react'
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

export default function TaskFeedScreen() {
  const [tasks, setTasks] = useState<AskTask[]>([])
  const [loading, setLoading] = useState(true)
  const navigate = useNavigate()

  useEffect(() => {
    getTasks().then(t => { setTasks(t); setLoading(false) })
  }, [])

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 pt-12 pb-3 border-b border-ask-sep">
        <h1 className="text-xl font-bold text-white">Feed</h1>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar">
        {loading ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Loading...</div>
        ) : tasks.length === 0 ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No tasks</div>
        ) : (
          <div className="flex flex-col divide-y divide-ask-sep">
            {tasks.map(task => (
              <button
                key={task.taskID}
                onClick={() => navigate(`/tasks/${task.taskID}`)}
                className="flex items-start gap-3 px-4 py-3 hover:bg-white/5 transition-colors text-left w-full"
              >
                <div className={`w-2 h-2 rounded-full mt-1.5 flex-shrink-0 ${task.status === 'running' ? 'bg-ask-blue' : 'bg-ask-green'}`} />
                <div className="flex-1 min-w-0">
                  <p className="text-sm text-white font-medium truncate">{task.title}</p>
                  <p className="text-xs text-ask-secondary">{task.scriptName} · {task.messageCount} messages</p>
                </div>
                <span className="text-[10px] text-ask-secondary flex-shrink-0">{relativeTime(task.lastActivityAt)}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
