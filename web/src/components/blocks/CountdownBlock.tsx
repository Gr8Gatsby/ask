import { useState, useEffect } from 'react'
import type { CountdownPayload } from '../../lib/types'

interface Props { payload: CountdownPayload }

function formatCountdown(target: Date): string {
  const diff = target.getTime() - Date.now()
  if (diff <= 0) return 'overdue'
  const h = Math.floor(diff / 3_600_000)
  const m = Math.floor((diff % 3_600_000) / 60_000)
  if (h > 48) return `in ${Math.floor(h / 24)} days`
  if (h > 0) return `about ${h} hour${h !== 1 ? 's' : ''}`
  return `${m} minute${m !== 1 ? 's' : ''}`
}

export default function CountdownBlock({ payload }: Props) {
  const target = new Date(payload.time)
  const [display, setDisplay] = useState(() => formatCountdown(target))

  useEffect(() => {
    const id = setInterval(() => setDisplay(formatCountdown(target)), 30_000)
    return () => clearInterval(id)
  }, [payload.time])

  const overdue = display === 'overdue'

  return (
    <div className="flex items-center gap-2">
      <div className={`w-2 h-2 rounded-full flex-shrink-0 ${overdue ? 'bg-ask-red' : 'bg-ask-orange'}`} />
      <span className="text-sm font-semibold text-white">{payload.label}</span>
      <span className={`text-sm ml-auto ${overdue ? 'text-ask-red' : 'text-ask-secondary'}`}>{display}</span>
    </div>
  )
}
