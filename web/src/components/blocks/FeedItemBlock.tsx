import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import type { FeedItemPayload, StatusColor } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

const COLOR: Record<StatusColor, string> = {
  green:  'bg-ask-green', blue:   'bg-ask-blue',
  orange: 'bg-ask-orange', red:    'bg-ask-red', yellow: 'bg-ask-yellow',
}

const MUI_DOT_COLOR: Record<StatusColor, string> = {
  green: '#a8c7a0', blue: '#d0bcff', orange: '#ffb74d', red: '#f2b8b5', yellow: '#f6d860',
}

interface Props { payload: FeedItemPayload }

export default function FeedItemBlock({ payload }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    const dotColor = payload.color ? MUI_DOT_COLOR[payload.color] : '#cac4d0'
    return (
      <Box sx={{ display: 'flex', alignItems: 'flex-start', gap: 1.5 }}>
        <Box sx={{ width: 8, height: 8, borderRadius: '50%', bgcolor: dotColor, mt: '6px', flexShrink: 0 }} />
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="body2" sx={{ fontWeight: 500 }}>{payload.title}</Typography>
          {payload.body && <Typography variant="body2" color="text.secondary">{payload.body}</Typography>}
        </Box>
        {payload.timestamp && (
          <Typography variant="caption" color="text.secondary" sx={{ flexShrink: 0 }}>
            {new Date(payload.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          </Typography>
        )}
      </Box>
    )
  }

  const dot = payload.color ? COLOR[payload.color] : 'bg-ask-secondary'
  return (
    <div className="flex items-start gap-2">
      <div className={`w-2 h-2 rounded-full mt-1.5 flex-shrink-0 ${dot}`} />
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-ask-text">{payload.title}</p>
        {payload.body && <p className="text-xs text-ask-secondary mt-0.5">{payload.body}</p>}
      </div>
      {payload.timestamp && (
        <span className="text-[10px] text-ask-secondary flex-shrink-0">
          {new Date(payload.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
        </span>
      )}
    </div>
  )
}
