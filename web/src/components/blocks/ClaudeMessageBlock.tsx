import Paper from '@mui/material/Paper'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Avatar from '@mui/material/Avatar'
import type { Block, ClaudeMessagePayload } from '../../lib/types'
import Markdown from '../shared/Markdown'
import { useTheme } from '../../lib/PlatformContext'

interface Props { block: Block; payload: ClaudeMessagePayload }

export default function ClaudeMessageBlock({ block: _block, payload }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <Avatar sx={{ width: 20, height: 20, bgcolor: '#74AA9C', fontSize: 9, fontWeight: 'bold' }}>C</Avatar>
          <Typography variant="caption" color="text.secondary">Claude Code</Typography>
        </Box>
        <Paper variant="outlined" sx={{ p: 1.5, borderRadius: 2 }}>
          <Markdown>{payload.text}</Markdown>
        </Paper>
      </Box>
    )
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-1.5">
        <div className="w-5 h-5 rounded-full bg-[#74AA9C] flex items-center justify-center text-[9px] font-bold text-white">C</div>
        <span className="text-xs font-medium text-ask-secondary">Claude Code</span>
      </div>
      <div className="border-t border-ask-sep pt-2">
        <Markdown>{payload.text}</Markdown>
      </div>
    </div>
  )
}
