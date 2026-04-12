import { useState } from 'react'
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

  return (
    <div className="flex flex-col gap-3">
      <p className={`${theme.typeTitleMedium} text-white`}>{payload.title}</p>

      {payload.multiline ? (
        <textarea
          value={value}
          onChange={e => setValue(e.target.value)}
          placeholder={payload.placeholder ?? ''}
          rows={4}
          className={`${theme.input} resize-none`}
        />
      ) : (
        <input
          type="text"
          value={value}
          onChange={e => setValue(e.target.value)}
          placeholder={payload.placeholder ?? ''}
          onKeyDown={e => { if (e.key === 'Enter') submit() }}
          className={theme.input}
        />
      )}

      <button
        onClick={submit}
        disabled={!value.trim()}
        className={`${theme.btnFilled} disabled:opacity-40`}
      >
        Submit
      </button>
    </div>
  )
}
