import Chip from '@mui/material/Chip'
import Typography from '@mui/material/Typography'
import Box from '@mui/material/Box'
import type { StatusPayload, StatusColor } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

const DOT_COLOR: Record<StatusColor, string> = {
  green:  'bg-ask-green',
  blue:   'bg-ask-blue',
  orange: 'bg-ask-orange',
  red:    'bg-ask-red',
  yellow: 'bg-ask-yellow',
}

// Map status color to MUI color for Chip
const MUI_COLOR: Record<StatusColor, 'success' | 'primary' | 'warning' | 'error' | 'default'> = {
  green: 'success', blue: 'primary', orange: 'warning', red: 'error', yellow: 'default',
}

interface Props { payload: StatusPayload }

export default function StatusBlock({ payload }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    const color = payload.color ? MUI_COLOR[payload.color] : 'default'
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <Chip label={payload.label} color={color} size="small" variant="outlined" />
        </Box>
        {payload.detail && (
          <Typography variant="body2" color="text.secondary">{payload.detail}</Typography>
        )}
      </Box>
    )
  }

  const dot = payload.color ? DOT_COLOR[payload.color] : 'bg-ask-secondary'
  return (
    <div className="flex items-start gap-2">
      <div className={`w-2 h-2 rounded-full mt-1.5 flex-shrink-0 ${dot}`} />
      <div>
        <p className="text-sm font-semibold text-ask-text">{payload.label}</p>
        {payload.detail && <p className="text-xs text-ask-secondary mt-0.5">{payload.detail}</p>}
      </div>
    </div>
  )
}
