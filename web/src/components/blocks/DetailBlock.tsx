import Button from '@mui/material/Button'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import Divider from '@mui/material/Divider'
import type { Block, DetailPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: DetailPayload
  onRespond: (blockID: string, value: string) => void
}

export default function DetailBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    return (
      <Stack spacing={1.5}>
        <Typography variant="body1" sx={{ fontWeight: 500 }}>{payload.title}</Typography>
        <Divider />
        <Typography variant="body2" color="text.secondary" sx={{ whiteSpace: 'pre-wrap' }}>{payload.body}</Typography>
        {payload.actions && payload.actions.length > 0 && (
          <Stack direction="row" spacing={1} sx={{ flexWrap: 'wrap' }}>
            {payload.actions.map(action => (
              <Button key={action} variant="outlined" size="small" onClick={() => onRespond(block.blockID, action)}>
                {action}
              </Button>
            ))}
          </Stack>
        )}
      </Stack>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm font-semibold text-ask-text">{payload.title}</p>
      <div className="border-t border-ask-sep pt-2">
        <p className="text-xs text-ask-secondary leading-relaxed whitespace-pre-wrap">{payload.body}</p>
      </div>
      {payload.actions && payload.actions.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {payload.actions.map(action => (
            <button key={action} onClick={() => onRespond(block.blockID, action)} className="flex-1 min-w-[80px] py-2 rounded-lg bg-ask-card2 text-sm font-medium text-ask-text hover:bg-ask-blue hover:text-white transition-colors">
              {action}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
