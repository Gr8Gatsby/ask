import { useState } from 'react'
import type { Block, ChatPromptPayload } from '../../lib/types'
import Markdown from '../shared/Markdown'

interface Props {
  block: Block
  payload: ChatPromptPayload
  onRespond: (blockID: string, value: string) => void
}

export default function ChatPromptBlock({ block, payload, onRespond }: Props) {
  const [value, setValue] = useState('')

  const submit = () => {
    if (!value.trim()) return
    onRespond(block.blockID, value.trim())
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
        <input
          type="text"
          value={value}
          onChange={e => setValue(e.target.value)}
          placeholder={payload.placeholder ?? 'Reply to Claude...'}
          onKeyDown={e => { if (e.key === 'Enter') submit() }}
          className="flex-1 bg-ask-card2 rounded-lg px-3 py-2 text-sm text-ask-text placeholder-ask-secondary outline-none focus:ring-1 focus:ring-ask-blue"
        />
        <button
          onClick={submit}
          disabled={!value.trim()}
          className="px-4 py-2 rounded-lg bg-ask-blue text-white text-sm font-semibold disabled:opacity-40 hover:bg-ask-blue/80 transition-colors"
        >
          Send
        </button>
      </div>
    </div>
  )
}
