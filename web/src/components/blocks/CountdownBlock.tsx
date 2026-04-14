import { useState, useEffect } from 'react'
import Chip from '@mui/material/Chip'
import Typography from '@mui/material/Typography'
import Box from '@mui/material/Box'
import type { CountdownPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

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
  const theme = useTheme()
  const target = new Date(payload.time)
  const [display, setDisplay] = useState(() => formatCountdown(target))

  useEffect(() => {
    const diff = target.getTime() - Date.now()
    const interval = diff > 3_600_000 ? 30_000 : 1_000
    const id = setInterval(() => setDisplay(formatCountdown(target)), interval)
    return () => clearInterval(id)
  }, [payload.time])

  const overdue = display === 'overdue'

  if (theme.isAndroid) {
    return (
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
        <Typography variant="body2" sx={{ flex: 1 }}>{payload.label}</Typography>
        <Chip label={display} size="small" color={overdue ? 'error' : 'warning'} variant="outlined" />
      </Box>
    )
  }

  return (
    <div className="flex items-center gap-2">
      <div className={`w-2 h-2 rounded-full flex-shrink-0 ${overdue ? 'bg-ask-red' : 'bg-ask-orange'}`} />
      <span className="text-sm font-semibold text-ask-text">{payload.label}</span>
      <span className={`text-sm ml-auto font-mono tabular-nums ${overdue ? 'text-ask-red' : 'text-ask-secondary'}`}>{display}</span>
    </div>
  )
}
