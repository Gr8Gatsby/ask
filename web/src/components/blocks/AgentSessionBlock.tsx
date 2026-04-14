import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import Paper from '@mui/material/Paper'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import TextField from '@mui/material/TextField'
import IconButton from '@mui/material/IconButton'
// Icons via Material Symbols Rounded web font
import type { Block, AgentSessionPayload } from '../../lib/types'
import Markdown from '../shared/Markdown'
import { useTheme } from '../../lib/PlatformContext'
import { useSettings } from '../../lib/SettingsContext'

interface Props {
  block: Block
  payload: AgentSessionPayload
  onRespond: (blockID: string, value: string) => void
}

export default function AgentSessionBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const [reply, setReply] = useState('')
  const [collapsed, setCollapsed] = useState(false)
  const navigate = useNavigate()

  const { useBrandColors } = useSettings()
  const accentColor = useBrandColors ? (payload.brand_color ?? '#8E8E93') : '#8E8E93'

  const submit = () => {
    if (!reply.trim()) return
    onRespond(block.blockID, reply.trim())
    setReply('')
  }

  if (theme.isAndroid) {
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
        {/* Header */}
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <Box sx={{ width: 8, height: 8, borderRadius: '50%', bgcolor: payload.is_working ? accentColor : 'text.disabled', flexShrink: 0 }} />
          <Typography variant="body2" sx={{ fontWeight: 500, flex: 1 }} noWrap>{payload.project}</Typography>
          {payload.task_id && (
            <Typography
              variant="caption"
              color="primary"
              sx={{ cursor: 'pointer' }}
              onClick={() => navigate(`/tasks/${payload.task_id}`)}
            >
              View Feed
            </Typography>
          )}
          <IconButton size="small" onClick={() => setCollapsed(c => !c)}>
            <span className="mat-icon" style={{ fontSize: 20, fontVariationSettings: "'FILL' 0, 'wght' 400, 'opsz' 20" }}>
              {collapsed ? 'expand_more' : 'expand_less'}
            </span>
          </IconButton>
        </Box>

        {collapsed ? (
          <Typography variant="caption" color="text.secondary" noWrap>{payload.last_message ?? 'Working...'}</Typography>
        ) : (
          <>
            <Paper variant="outlined" sx={{ p: 1.5, borderRadius: 2, minHeight: 48 }}>
              {payload.is_working ? (
                <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                  {[0, 1, 2].map(i => (
                    <Box key={i} sx={{ width: 6, height: 6, borderRadius: '50%', bgcolor: accentColor, animation: 'bounce 1s infinite', animationDelay: `${i * 0.15}s` }} />
                  ))}
                  <Typography variant="caption" color="text.secondary">Working...</Typography>
                </Box>
              ) : payload.last_message ? (
                <Markdown>{payload.last_message}</Markdown>
              ) : (
                <Typography variant="caption" color="text.secondary">Session started</Typography>
              )}
            </Paper>
            <Box sx={{ display: 'flex', gap: 1 }}>
              <TextField
                fullWidth
                size="small"
                value={reply}
                onChange={e => setReply(e.target.value)}
                placeholder={payload.placeholder ?? 'Reply to Claude...'}
                onKeyDown={e => { if (e.key === 'Enter') submit() }}
              />
              <IconButton
                onClick={submit}
                disabled={!reply.trim()}
                sx={{ bgcolor: accentColor, color: 'white', borderRadius: 2, '&:hover': { bgcolor: accentColor, opacity: 0.8 }, '&.Mui-disabled': { bgcolor: 'action.disabledBackground' } }}
              >
                <span className="mat-icon" style={{ fontSize: 20, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 20" }}>send</span>
              </IconButton>
            </Box>
          </>
        )}
      </Box>
    )
  }

  // iOS (unchanged)
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-2">
        <div className={`w-2 h-2 rounded-full flex-shrink-0 ${!payload.is_working ? 'bg-ask-secondary' : ''}`} style={payload.is_working ? { backgroundColor: accentColor } : undefined} />
        <span className="flex-1 text-sm font-semibold text-ask-text truncate">{payload.project}</span>
        {payload.task_id && (
          <button onClick={() => navigate(`/tasks/${payload.task_id}`)} className="text-[10px] text-ask-blue hover:underline">View Feed</button>
        )}
        <button onClick={() => setCollapsed(c => !c)} className="text-ask-secondary text-xs hover:text-ask-text transition-colors">
          {collapsed ? '▼' : '▲'}
        </button>
      </div>
      {collapsed ? (
        <p className="text-xs text-ask-secondary truncate">{payload.last_message ?? 'Working...'}</p>
      ) : (
        <>
          <div className="bg-ask-card2 rounded-lg p-3 border border-ask-sep min-h-[48px]">
            {payload.is_working ? (
              <div className="flex items-center gap-2">
                <div className="flex gap-1">
                  {[0, 1, 2].map(i => (
                    <div key={i} className="w-1.5 h-1.5 rounded-full animate-bounce" style={{ backgroundColor: accentColor, animationDelay: `${i * 0.15}s` }} />
                  ))}
                </div>
                <span className="text-xs text-ask-secondary">Working...</span>
              </div>
            ) : payload.last_message ? (
              <Markdown>{payload.last_message}</Markdown>
            ) : (
              <span className="text-xs text-ask-secondary">Session started</span>
            )}
          </div>
          <div className="flex gap-2">
            <input type="text" value={reply} onChange={e => setReply(e.target.value)} placeholder={payload.placeholder ?? 'Reply to Claude...'} onKeyDown={e => { if (e.key === 'Enter') submit() }} className="flex-1 bg-ask-card2 rounded-lg px-3 py-2 text-sm text-ask-text placeholder-ask-secondary outline-none focus:ring-1 focus:ring-ask-blue" />
            <button onClick={submit} disabled={!reply.trim()} className="px-4 py-2 rounded-lg text-white text-sm font-semibold disabled:opacity-40 transition-colors hover:opacity-80" style={{ backgroundColor: accentColor }}>→</button>
          </div>
        </>
      )}
    </div>
  )
}
