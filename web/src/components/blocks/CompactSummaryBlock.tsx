import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import type { CompactSummaryPayload } from '../../lib/types'
import Markdown from '../shared/Markdown'
import { useTheme } from '../../lib/PlatformContext'

interface Props { payload: CompactSummaryPayload }

export default function CompactSummaryBlock({ payload }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <Typography variant="caption" color="text.secondary" sx={{ textTransform: 'uppercase', letterSpacing: '0.4px', fontSize: 11, fontWeight: 500 }}>
            {payload.project}
          </Typography>
          {payload.trigger && (
            <Typography variant="caption" color="text.disabled">· {payload.trigger}</Typography>
          )}
        </Box>
        <Typography variant="body2" color="text.secondary" sx={{ overflow: 'hidden', display: '-webkit-box', WebkitLineClamp: 4, WebkitBoxOrient: 'vertical' }}>
          <Markdown>{payload.summary}</Markdown>
        </Typography>
      </Box>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2">
        <span className="text-[10px] font-bold text-ask-secondary uppercase tracking-wide">{payload.project}</span>
        {payload.trigger && <span className="text-[10px] text-ask-secondary/60">· {payload.trigger}</span>}
      </div>
      <div className="text-xs text-ask-secondary leading-relaxed line-clamp-4">
        <Markdown>{payload.summary}</Markdown>
      </div>
    </div>
  )
}
