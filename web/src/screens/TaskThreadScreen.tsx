import { useState, useEffect, useRef } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { getTaskMessages, getTasks } from '../lib/api'
import type { AskTask, TaskMessage } from '../lib/types'
import Markdown from '../components/shared/Markdown'

interface MessagePart { type: string; text?: string }

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

  function renderParts(partsJSON: string) {
    try {
      const parts = JSON.parse(partsJSON) as MessagePart[]
      return parts.map((p, i) => (
        p.type === 'text' && p.text
          ? <Markdown key={i}>{p.text}</Markdown>
          : <span key={i} className="text-[10px] font-mono text-ask-secondary">[{p.type}]</span>
      ))
    } catch {
      return <span className="text-xs text-ask-secondary">{partsJSON}</span>
    }
  }

  return (
    <div className="flex flex-col h-full">
      <div className="flex items-center gap-3 px-4 pt-12 pb-3 border-b border-ask-sep">
        <button onClick={() => navigate(-1)} className="text-ask-blue text-sm">‹ Back</button>
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-white truncate">{task?.title ?? 'Task'}</p>
          <p className="text-[10px] text-ask-secondary">{task?.scriptName}</p>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar px-4 py-3 flex flex-col gap-3">
        {loading ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Loading...</div>
        ) : (
          messages.map(msg => (
            <div
              key={msg.messageID}
              className={`flex ${msg.role === 'user' ? 'justify-end' : 'justify-start'}`}
            >
              <div
                className={`max-w-[80%] rounded-2xl px-3 py-2 ${
                  msg.role === 'user'
                    ? 'bg-ask-blue rounded-br-sm'
                    : 'bg-ask-card rounded-bl-sm'
                }`}
              >
                {renderParts(msg.partsJSON)}
              </div>
            </div>
          ))
        )}
        <div ref={bottomRef} />
      </div>
    </div>
  )
}
