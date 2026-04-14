import Button from '@mui/material/Button'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import Box from '@mui/material/Box'
import type { Block, ConfirmationPayload } from '../../lib/types'
import { useTheme, PlatformIcon, usePlatform } from '../../lib/PlatformContext'
import { M3_BANNER_COLORS, M3_BANNER_COLORS_LIGHT } from '../../lib/muiTheme'

interface Props {
  block: Block
  payload: ConfirmationPayload
  onRespond: (blockID: string, value: string) => void
}

function PermissionBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const { themeMode } = usePlatform()
  const denyWords = ['deny', 'cancel', 'no', 'reject']
  const allowWords = ['allow', 'yes', 'approve', 'permit']

  function classify(opt: string) {
    const l = opt.toLowerCase()
    if (denyWords.some(w => l.includes(w))) return 'deny'
    if (allowWords.some(w => l.includes(w))) return 'allow'
    return 'neutral'
  }

  if (theme.isAndroid) {
    const colors = themeMode === 'light' ? M3_BANNER_COLORS_LIGHT : M3_BANNER_COLORS
    const { bg, icon: iconColor, border } = colors.warning
    return (
      <Stack spacing={2}>
        <Box sx={{ display: 'flex', alignItems: 'flex-start', gap: 1.5, px: 2, py: 1.5, bgcolor: bg, border: `1px solid ${border}`, borderRadius: '12px' }}>
          <span className="mat-icon" style={{ fontSize: 20, color: iconColor, flexShrink: 0, marginTop: '2px', fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 20" }}>security</span>
          <Box sx={{ flex: 1, minWidth: 0 }}>
            <Typography variant="subtitle1" component="p" sx={{ color: 'text.primary', lineHeight: '24px' }}>Permission needed</Typography>
            <Typography variant="body2" sx={{ color: 'text.secondary', mt: 0.25 }}>{payload.title}</Typography>
            {payload.body && <Typography variant="body2" color="text.secondary" sx={{ mt: 0.25 }}>{payload.body}</Typography>}
          </Box>
        </Box>
        {payload.command && (
          <Box sx={{ bgcolor: 'background.paper', borderRadius: 2, border: '1px solid', borderColor: 'divider', p: 1.5 }}>
            <Typography variant="caption" color="text.secondary" sx={{ display: 'block', mb: 0.5 }}>Command</Typography>
            <Typography component="pre" variant="caption" sx={{ fontFamily: 'monospace', whiteSpace: 'pre-wrap', wordBreak: 'break-all' }}>
              {payload.command}
            </Typography>
          </Box>
        )}
        <Stack spacing={1}>
          {payload.options.map(opt => {
            const kind = classify(opt)
            return (
              <Button
                key={opt}
                fullWidth
                variant={kind === 'allow' ? 'contained' : 'outlined'}
                color={kind === 'allow' ? 'success' : kind === 'deny' ? 'error' : 'primary'}
                onClick={() => onRespond(block.blockID, opt)}
              >
                {opt}
              </Button>
            )
          })}
        </Stack>
      </Stack>
    )
  }

  // iOS
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-1.5">
        <PlatformIcon ios="⚠" android="security" fill size={14} className="text-ask-orange" />
        <span className={`${theme.sectionHeader} text-ask-orange`}>Permission needed</span>
      </div>
      <p className={`${theme.typeTitleMedium} text-ask-text`}>{payload.title}</p>
      {payload.body && <p className={`${theme.typeBodyMedium} text-ask-secondary`}>{payload.body}</p>}
      {payload.command && (
        <div className="rounded-xl bg-ask-card2 border border-ask-sep/40 px-3 py-2.5">
          <p className={`${theme.typeLabelMedium} text-ask-secondary mb-1.5`}>Bash wants to run:</p>
          <pre className="text-xs font-mono text-ask-text whitespace-pre-wrap break-all leading-relaxed">{payload.command}</pre>
        </div>
      )}
      <div className="flex flex-col gap-2">
        {payload.options.map(opt => {
          const kind = classify(opt)
          return (
            <button key={opt} onClick={() => onRespond(block.blockID, opt)}
              className={kind === 'allow' ? theme.btnAllow : kind === 'deny' ? theme.btnDeny : theme.btnOutlined}>
              {opt}
            </button>
          )
        })}
      </div>
    </div>
  )
}

export default function ConfirmationBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const { themeMode } = usePlatform()

  if (payload.command) {
    return <PermissionBlock block={block} payload={payload} onRespond={onRespond} />
  }

  const urgency = payload.urgency ?? 'warning'
  const inline = payload.options.length <= 2

  if (theme.isAndroid) {
    const severity = urgency === 'urgent' ? 'error' : urgency === 'warning' ? 'warning' : 'info'
    const iconName = severity === 'error' ? 'error' : severity === 'warning' ? 'warning' : 'info'
    const colors = themeMode === 'light' ? M3_BANNER_COLORS_LIGHT : M3_BANNER_COLORS
    const { bg, icon: iconColor, border } = colors[severity]
    return (
      <Stack spacing={2}>
        <Box sx={{ display: 'flex', alignItems: 'flex-start', gap: 1.5, px: 2, py: 1.5, bgcolor: bg, border: `1px solid ${border}`, borderRadius: '12px' }}>
          <span className="mat-icon" style={{ fontSize: 20, color: iconColor, flexShrink: 0, marginTop: '2px', fontVariationSettings: "'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 20" }}>{iconName}</span>
          <Box sx={{ flex: 1, minWidth: 0 }}>
            <Typography variant="subtitle1" component="p" sx={{ color: 'text.primary', lineHeight: '24px' }}>{payload.title}</Typography>
            {payload.body && <Typography variant="body2" sx={{ color: 'text.secondary', mt: 0.25 }}>{payload.body}</Typography>}
          </Box>
        </Box>
        {inline ? (
          <Stack direction="row" spacing={1} sx={{ justifyContent: 'flex-end' }}>
            {payload.options.map((opt, i) => (
              <Button
                key={opt}
                variant={i === payload.options.length - 1 ? 'contained' : 'text'}
                onClick={() => onRespond(block.blockID, opt)}
              >
                {opt}
              </Button>
            ))}
          </Stack>
        ) : (
          <Stack spacing={1}>
            {payload.options.map((opt, i) => (
              <Button key={opt} fullWidth variant={i === 0 ? 'contained' : 'outlined'} onClick={() => onRespond(block.blockID, opt)}>
                {opt}
              </Button>
            ))}
          </Stack>
        )}
      </Stack>
    )
  }

  // iOS
  const urgencyIcon = urgency === 'urgent'
    ? { ios: '⚠', android: 'error', color: 'text-ask-red' }
    : urgency === 'info'
    ? { ios: 'ℹ', android: 'info', color: 'text-ask-blue' }
    : { ios: '⚠', android: 'warning', color: 'text-ask-orange' }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-start gap-2">
        <PlatformIcon ios={urgencyIcon.ios} android={urgencyIcon.android} fill size={16} className={`flex-shrink-0 mt-0.5 ${urgencyIcon.color}`} />
        <div className="flex-1 min-w-0">
          <p className={`${theme.typeTitleMedium} text-ask-text leading-snug`}>{payload.title}</p>
          {payload.body && <p className={`${theme.typeBodyMedium} text-ask-secondary mt-0.5`}>{payload.body}</p>}
        </div>
      </div>
      <div className={theme.optionContainer}>
        {payload.options.map(opt => (
          <button key={opt} onClick={() => onRespond(block.blockID, opt)} className={theme.optionBtnPrimary}>{opt}</button>
        ))}
      </div>
    </div>
  )
}
