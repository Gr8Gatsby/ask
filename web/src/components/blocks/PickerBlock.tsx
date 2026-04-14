import { useState } from 'react'
import Button from '@mui/material/Button'
import FormControl from '@mui/material/FormControl'
import InputLabel from '@mui/material/InputLabel'
import Select from '@mui/material/Select'
import MenuItem from '@mui/material/MenuItem'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import type { Block, PickerPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: PickerPayload
  onRespond: (blockID: string, value: string) => void
}

export default function PickerBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const [selected, setSelected] = useState(payload.selected ?? payload.options[0] ?? '')

  if (theme.isAndroid) {
    return (
      <Stack spacing={2}>
        <Typography variant="body1" sx={{ fontWeight: 500 }}>{payload.title}</Typography>
        <FormControl fullWidth size="small">
          <InputLabel>Option</InputLabel>
          <Select value={selected} label="Option" onChange={e => setSelected(e.target.value)}>
            {payload.options.map(opt => <MenuItem key={opt} value={opt}>{opt}</MenuItem>)}
          </Select>
        </FormControl>
        <Button variant="contained" onClick={() => onRespond(block.blockID, selected)} fullWidth>
          Select
        </Button>
      </Stack>
    )
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm font-semibold text-ask-text">{payload.title}</p>
      <select value={selected} onChange={e => setSelected(e.target.value)} className="w-full bg-ask-card2 rounded-lg px-3 py-2 text-sm text-ask-text outline-none focus:ring-1 focus:ring-ask-blue appearance-none">
        {payload.options.map(opt => <option key={opt} value={opt}>{opt}</option>)}
      </select>
      <button onClick={() => onRespond(block.blockID, selected)} className="w-full py-2 rounded-lg bg-ask-blue text-white text-sm font-semibold hover:bg-ask-blue/80 transition-colors">
        Select
      </button>
    </div>
  )
}
