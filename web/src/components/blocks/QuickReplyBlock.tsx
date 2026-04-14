import { useState } from 'react'
import Button from '@mui/material/Button'
import Stack from '@mui/material/Stack'
import TextField from '@mui/material/TextField'
import type { Block, QuickReplyPayload } from '../../lib/types'
import { useTheme, PlatformIcon } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: QuickReplyPayload
  onRespond: (blockID: string, value: string) => void
}

export default function QuickReplyBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const [customText, setCustomText] = useState('')
  const [showCustom, setShowCustom] = useState(false)

  function respond(value: string) { onRespond(block.blockID, value) }

  const urgencyColor = payload.urgency === 'urgent' ? 'text-ask-red'
    : payload.urgency === 'info' ? 'text-ask-blue' : 'text-ask-orange'
  const urgencyIcon = payload.urgency === 'urgent' ? { ios: '⚠', android: 'warning' }
    : payload.urgency === 'info' ? { ios: 'ℹ', android: 'info' }
    : { ios: '⚠', android: 'warning' }

  if (theme.isAndroid) {
    return (
      <Stack spacing={2}>
        <div>
          <div className="flex items-start gap-2 mb-1">
            <PlatformIcon ios={urgencyIcon.ios} android={urgencyIcon.android} fill size={20} className={urgencyColor} />
            <div>
              <p className={`${theme.typeTitleMedium} text-ask-text`}>{payload.title}</p>
              {payload.description && <p className={`${theme.typeBodySmall} text-ask-secondary`}>{payload.description}</p>}
            </div>
          </div>
        </div>
        {showCustom ? (
          <Stack direction="row" spacing={1}>
            <TextField
              fullWidth
              autoFocus
              size="small"
              value={customText}
              onChange={e => setCustomText(e.target.value)}
              onKeyDown={e => { if (e.key === 'Enter' && customText.trim()) respond(customText.trim()) }}
              placeholder="Custom reply…"
            />
            <Button variant="text" onClick={() => setShowCustom(false)}>Cancel</Button>
          </Stack>
        ) : (
          <Stack spacing={1}>
            {payload.options.map((opt, i) => (
              <Button key={opt} fullWidth variant={i === 0 ? 'contained' : 'outlined'} onClick={() => respond(opt)}>
                {opt}
              </Button>
            ))}
            {payload.allow_custom && (
              <Button fullWidth variant="text" onClick={() => setShowCustom(true)}>Other…</Button>
            )}
          </Stack>
        )}
      </Stack>
    )
  }

  // iOS
  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-start gap-2">
        <PlatformIcon ios={urgencyIcon.ios} android={urgencyIcon.android} fill size={16} className={urgencyColor} />
        <div className="flex-1 min-w-0">
          <p className={`${theme.typeTitleMedium} text-ask-text`}>{payload.title}</p>
          {payload.description && <p className={`${theme.typeBodySmall} text-ask-secondary mt-0.5`}>{payload.description}</p>}
        </div>
      </div>
      {showCustom ? (
        <div className="flex gap-2">
          <input autoFocus type="text" value={customText} onChange={e => setCustomText(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter' && customText.trim()) respond(customText.trim()) }}
            placeholder="Custom reply…" className={theme.input} />
          <button onClick={() => setShowCustom(false)} className={theme.btnText}>Cancel</button>
        </div>
      ) : (
        <div className={theme.optionContainer}>
          {payload.options.map(opt => (
            <button key={opt} onClick={() => respond(opt)} className={theme.optionBtnPrimary}>{opt}</button>
          ))}
          {payload.allow_custom && (
            <button onClick={() => setShowCustom(true)} className={theme.optionBtnSecondary}>Other…</button>
          )}
        </div>
      )}
    </div>
  )
}
