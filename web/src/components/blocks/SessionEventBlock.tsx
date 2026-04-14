import Chip from '@mui/material/Chip'
import Box from '@mui/material/Box'
import type { SessionEventPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props { payload: SessionEventPayload }

export default function SessionEventBlock({ payload }: Props) {
  const theme = useTheme()
  const started = payload.event === 'started'

  if (theme.isAndroid) {
    const label = `${started ? 'Session started' : 'Session stopped'}${payload.project ? ` · ${payload.project}` : ''}`
    return (
      <Box sx={{ display: 'flex', alignItems: 'center' }}>
        <Chip
          label={label}
          size="small"
          color={started ? 'success' : 'default'}
          variant="outlined"
        />
      </Box>
    )
  }

  return (
    <div className="flex items-center gap-2 py-1">
      <div className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${started ? 'bg-ask-green' : 'bg-ask-secondary'}`} />
      <span className="text-xs text-ask-secondary">
        {started ? 'Session started' : 'Session stopped'}
        {payload.project && <> · <span className="text-ask-text/70">{payload.project}</span></>}
      </span>
    </div>
  )
}
