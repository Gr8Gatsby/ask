import { useState } from 'react'
import Paper from '@mui/material/Paper'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import TextField from '@mui/material/TextField'
import IconButton from '@mui/material/IconButton'
import Avatar from '@mui/material/Avatar'
// Icons via Material Symbols Rounded web font
import type { Block, ChatPromptPayload } from '../../lib/types'
import Markdown from '../shared/Markdown'
import { useTheme } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: ChatPromptPayload
  onRespond: (blockID: string, value: string) => void
}

export default function ChatPromptBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const [value, setValue] = useState('')

  const submit = () => {
    if (!value.trim()) return
    onRespond(block.blockID, value.trim())
  }

  if (theme.isAndroid) {
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1.5 }}>
        {payload.context && (
          <Paper variant="outlined" sx={{ p: 1.5, borderRadius: 2 }}>
            <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
              <Avatar sx={{ width: 16, height: 16, bgcolor: '#74AA9C', fontSize: 8, fontWeight: 'bold' }}>C</Avatar>
              <Typography variant="caption" color="text.secondary">Claude Code</Typography>
            </Box>
            <Markdown>{payload.context}</Markdown>
          </Paper>
        )}
        <Box sx={{ display: 'flex', gap: 1 }}>
          <TextField
            fullWidth
            size="small"
            value={value}
            onChange={e => setValue(e.target.value)}
            placeholder={payload.placeholder ?? 'Reply to Claude...'}
            onKeyDown={e => { if (e.key === 'Enter') submit() }}
          />
          <IconButton onClick={submit} disabled={!value.trim()} color="primary" sx={{ borderRadius: 2 }}>
            <span className="mat-icon" style={{ fontSize: 20, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 20" }}>send</span>
          </IconButton>
        </Box>
      </Box>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      {payload.context && (
        <div className="bg-ask-card2 rounded-lg p-3 border border-ask-sep">
          <div className="flex items-center gap-1.5 mb-2">
            <div className="w-4 h-4 rounded-full bg-[#74AA9C] flex items-center justify-center text-[8px] font-bold text-white">C</div>
            <span className="text-xs font-medium text-ask-secondary">Claude Code</span>
          </div>
          <Markdown>{payload.context}</Markdown>
        </div>
      )}
      <div className="flex gap-2">
        <input type="text" value={value} onChange={e => setValue(e.target.value)} placeholder={payload.placeholder ?? 'Reply to Claude...'} onKeyDown={e => { if (e.key === 'Enter') submit() }} className="flex-1 bg-ask-card2 rounded-lg px-3 py-2 text-sm text-ask-text placeholder-ask-secondary outline-none focus:ring-1 focus:ring-ask-blue" />
        <button onClick={submit} disabled={!value.trim()} className="px-4 py-2 rounded-lg bg-ask-blue text-white text-sm font-semibold disabled:opacity-40 hover:bg-ask-blue/80 transition-colors">Send</button>
      </div>
    </div>
  )
}
