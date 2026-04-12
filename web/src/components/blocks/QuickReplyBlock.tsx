import { useState } from 'react'
import type { Block, QuickReplyPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'
import UrgencyBadge from '../shared/UrgencyBadge'

interface Props {
  block: Block
  payload: QuickReplyPayload
  onRespond: (blockID: string, value: string) => void
}

export default function QuickReplyBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const [customText, setCustomText] = useState('')
  const [showCustom, setShowCustom] = useState(false)
  const inline = payload.options.length <= 2 && !payload.allow_custom

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-start gap-2">
        <UrgencyBadge urgency={payload.urgency ?? 'warning'} />
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-white leading-snug">{payload.title}</p>
          {payload.description && <p className="text-xs text-ask-secondary truncate">{payload.description}</p>}
        </div>
      </div>

      {showCustom ? (
        <div className="flex gap-2">
          <input
            autoFocus
            type="text"
            value={customText}
            onChange={e => setCustomText(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter' && customText.trim()) onRespond(block.blockID, customText.trim()) }}
            placeholder="Custom reply..."
            className="flex-1 bg-ask-card2 rounded-lg px-3 py-1.5 text-sm text-white placeholder-ask-secondary outline-none focus:ring-1 focus:ring-ask-blue"
          />
          <button onClick={() => setShowCustom(false)} className="text-xs text-ask-secondary hover:text-white">Cancel</button>
        </div>
      ) : (
        <div className={inline ? 'flex gap-2' : 'flex flex-col gap-1.5'}>
          {payload.options.map(opt => (
            <button
              key={opt}
              onClick={() => onRespond(block.blockID, opt)}
              className={`${inline ? 'flex-1' : 'w-full text-left'} py-1.5 px-3 text-sm font-medium active:scale-[0.98] ${theme.buttonOption}`}
            >
              {opt}
            </button>
          ))}
          {payload.allow_custom && (
            <button
              onClick={() => setShowCustom(true)}
              className={`w-full text-left py-1.5 px-3 text-sm text-ask-secondary hover:text-white transition-colors ${
                theme.isAndroid ? 'rounded-full' : 'rounded-lg'
              } bg-ask-card2`}
            >
              Custom...
            </button>
          )}
        </div>
      )}
    </div>
  )
}
