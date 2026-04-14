import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import type { AlertPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'
import { usePlatform, PlatformIcon } from '../../lib/PlatformContext'
import { M3_BANNER_COLORS, M3_BANNER_COLORS_LIGHT } from '../../lib/muiTheme'

interface Props { payload: AlertPayload }

export default function AlertBlock({ payload }: Props) {
  const theme = useTheme()
  const { themeMode } = usePlatform()

  const urgency = payload.urgency ?? 'info'

  if (theme.isAndroid) {
    // M3 Banner: no MUI Alert equivalent — tinted surface-variant container,
    // left Material Symbol icon, Title Medium + Body Medium text.
    const severity = urgency === 'urgent' ? 'error' : urgency === 'warning' ? 'warning' : 'info'
    const colors = themeMode === 'light' ? M3_BANNER_COLORS_LIGHT : M3_BANNER_COLORS
    const { bg, icon: iconColor, border } = colors[severity]
    const iconName = severity === 'error' ? 'error' : severity === 'warning' ? 'warning' : 'info'

    return (
      <Box sx={{
        display: 'flex', alignItems: 'flex-start', gap: 1.5,
        px: 2, py: 1.5,
        bgcolor: bg,
        border: `1px solid ${border}`,
        borderRadius: '12px',
      }}>
        <span
          className="mat-icon"
          style={{ fontSize: 20, color: iconColor, flexShrink: 0, marginTop: '2px',
            fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 20" }}
        >
          {iconName}
        </span>
        <Box sx={{ flex: 1, minWidth: 0 }}>
          <Typography variant="subtitle1" component="p" sx={{ color: 'text.primary', lineHeight: '24px' }}>
            {payload.title}
          </Typography>
          {payload.body && (
            <Typography variant="body2" sx={{ color: 'text.secondary', mt: 0.25 }}>
              {payload.body}
            </Typography>
          )}
        </Box>
      </Box>
    )
  }

  // iOS
  const icon = urgency === 'urgent'
    ? { ios: '⚠', android: 'error', color: 'text-ask-red' }
    : urgency === 'warning'
    ? { ios: '⚠', android: 'warning', color: 'text-ask-orange' }
    : { ios: 'ℹ', android: 'info', color: 'text-ask-blue' }

  return (
    <div className="flex items-start gap-2">
      <PlatformIcon ios={icon.ios} android={icon.android} fill size={17} className={`flex-shrink-0 mt-0.5 ${icon.color}`} />
      <div className="flex-1 min-w-0">
        <p className="text-[13px] font-semibold text-ask-text leading-snug">{payload.title}</p>
        {payload.body && (
          <p className="text-[11px] font-normal text-ask-secondary mt-[2px] leading-relaxed">{payload.body}</p>
        )}
      </div>
    </div>
  )
}
