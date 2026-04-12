import { useState } from 'react'
import type { Block, PromptPayload } from '../../lib/types'

interface Props {
  block: Block
  payload: PromptPayload
  onRespond: (blockID: string, value: string) => void
}

export default function PromptBlock({ block, payload, onRespond }: Props) {
  const [value, setValue] = useState('')

  const submit = () => {
    if (!value.trim()) return
    onRespond(block.blockID, value.trim())
  }

  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm font-semibold text-white">{payload.title}</p>
      {payload.multiline ? (
        <textarea
          value={value}
          onChange={e => setValue(e.target.value)}
          placeholder={payload.placeholder ?? ''}
          rows={4}
          className="w-full bg-ask-card2 rounded-lg px-3 py-2 text-sm text-white placeholder-ask-secondary resize-none outline-none focus:ring-1 focus:ring-ask-blue"
        />
      ) : (
        <input
          type="text"
          value={value}
          onChange={e => setValue(e.target.value)}
          placeholder={payload.placeholder ?? ''}
          onKeyDown={e => { if (e.key === 'Enter') submit() }}
          className="w-full bg-ask-card2 rounded-lg px-3 py-2 text-sm text-white placeholder-ask-secondary outline-none focus:ring-1 focus:ring-ask-blue"
        />
      )}
      <button
        onClick={submit}
        disabled={!value.trim()}
        className="w-full py-2 rounded-lg bg-ask-blue text-white text-sm font-semibold disabled:opacity-40 hover:bg-ask-blue/80 transition-colors"
      >
        Submit
      </button>
    </div>
  )
}
