import { useState } from 'react'
import Button from '@mui/material/Button'
import TextField from '@mui/material/TextField'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import type { Block, PromptPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: PromptPayload
  onRespond: (blockID: string, value: string) => void
}

export default function PromptBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const [value, setValue] = useState('')

  const submit = () => {
    if (!value.trim()) return
    onRespond(block.blockID, value.trim())
  }

  if (theme.isAndroid) {
    return (
      <Stack spacing={2}>
        <Typography variant="body1" sx={{ fontWeight: 500 }}>{payload.title}</Typography>
        <TextField
          fullWidth
          multiline={payload.multiline}
          rows={payload.multiline ? 4 : undefined}
          value={value}
          onChange={e => setValue(e.target.value)}
          placeholder={payload.placeholder ?? ''}
          onKeyDown={e => { if (!payload.multiline && e.key === 'Enter') submit() }}
        />
        <Button variant="contained" onClick={submit} disabled={!value.trim()} fullWidth>
          Submit
        </Button>
      </Stack>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      <p className={`${theme.typeTitleMedium} text-ask-text`}>{payload.title}</p>
      {payload.multiline ? (
        <textarea value={value} onChange={e => setValue(e.target.value)} placeholder={payload.placeholder ?? ''} rows={4} className={`${theme.input} resize-none`} />
      ) : (
        <input type="text" value={value} onChange={e => setValue(e.target.value)} placeholder={payload.placeholder ?? ''} onKeyDown={e => { if (e.key === 'Enter') submit() }} className={theme.input} />
      )}
      <button onClick={submit} disabled={!value.trim()} className={`${theme.btnFilled} disabled:opacity-40`}>Submit</button>
    </div>
  )
}
