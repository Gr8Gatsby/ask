import { useState, useEffect } from 'react'
import type { CountdownPayload } from '../../lib/types'

interface Props { payload: CountdownPayload }

function formatCountdown(target: Date): string {
  const diff = target.getTime() - Date.now()
  if (diff <= 0) return 'overdue'
  const h = Math.floor(diff / 3_600_000)
  const m = Math.floor((diff % 3_600_000) / 60_000)
  const s = Math.floor((diff % 60_000) / 1_000)
  if (h > 48) return `in ${Math.floor(h / 24)} days`
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m ${s}s`
  return `${s}s`
}

export default function CountdownBlock({ payload }: Props) {
  const target = new Date(payload.time)
  const [display, setDisplay] = useState(() => formatCountdown(target))

  useEffect(() => {
    const diff = target.getTime() - Date.now()
    const interval = diff > 3_600_000 ? 30_000 : 1_000
    const id = setInterval(() => setDisplay(formatCountdown(target)), interval)
    return () => clearInterval(id)
  }, [payload.time])

  const overdue = display === 'overdue'

  return (
    <div className="flex items-center gap-2">
      <div className={`w-2 h-2 rounded-full flex-shrink-0 ${overdue ? 'bg-ask-red' : 'bg-ask-orange'}`} />
      <span className="text-sm font-semibold text-ask-text">{payload.label}</span>
      <span className={`text-sm ml-auto font-mono tabular-nums ${overdue ? 'text-ask-red' : 'text-ask-secondary'}`}>{display}</span>
    </div>
  )
}
