import { useState } from 'react'
import type { Block, PickerPayload } from '../../lib/types'

interface Props {
  block: Block
  payload: PickerPayload
  onRespond: (blockID: string, value: string) => void
}

export default function PickerBlock({ block, payload, onRespond }: Props) {
  const [selected, setSelected] = useState(payload.selected ?? payload.options[0] ?? '')

  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm font-semibold text-white">{payload.title}</p>
      <select
        value={selected}
        onChange={e => setSelected(e.target.value)}
        className="w-full bg-ask-card2 rounded-lg px-3 py-2 text-sm text-white outline-none focus:ring-1 focus:ring-ask-blue appearance-none"
      >
        {payload.options.map(opt => (
          <option key={opt} value={opt}>{opt}</option>
        ))}
      </select>
      <button
        onClick={() => onRespond(block.blockID, selected)}
        className="w-full py-2 rounded-lg bg-ask-blue text-white text-sm font-semibold hover:bg-ask-blue/80 transition-colors"
      >
        Select
      </button>
    </div>
  )
}
