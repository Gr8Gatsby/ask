import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Avatar from '@mui/material/Avatar'
import type { IconCardPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props { payload: IconCardPayload }

export default function IconCardBlock({ payload }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    return (
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
        <Avatar variant="rounded" sx={{ bgcolor: 'action.selected', width: 40, height: 40 }}>
          <span style={{ fontSize: 20 }}>📋</span>
        </Avatar>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body1" sx={{ fontWeight: 500 }} noWrap>{payload.title}</Typography>
          {payload.subtitle && <Typography variant="body2" color="text.secondary" noWrap>{payload.subtitle}</Typography>}
        </Box>
      </Box>
    )
  }

  return (
    <div className="flex items-center gap-3">
      <div className="w-10 h-10 rounded-xl bg-ask-card2 flex items-center justify-center flex-shrink-0">
        <span className="text-xl">📋</span>
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-ask-text leading-tight">{payload.title}</p>
        {payload.subtitle && <p className="text-xs text-ask-secondary mt-0.5 truncate">{payload.subtitle}</p>}
      </div>
    </div>
  )
}
