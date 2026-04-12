import { useState } from 'react'
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

  function respond(value: string) {
    onRespond(block.blockID, value)
  }

  const urgencyColor = payload.urgency === 'urgent' ? 'text-ask-red'
    : payload.urgency === 'info' ? 'text-ask-blue'
    : 'text-ask-orange'

  const urgencyIcon = payload.urgency === 'urgent' ? { ios: '⚠', android: 'warning' }
    : payload.urgency === 'info' ? { ios: 'ℹ', android: 'info' }
    : { ios: '⚠', android: 'warning' }

  return (
    <div className="flex flex-col gap-3">
      {/* Header */}
      <div className="flex items-start gap-2">
        <PlatformIcon
          ios={urgencyIcon.ios}
          android={urgencyIcon.android}
          fill
          size={theme.isAndroid ? 20 : 16}
          className={urgencyColor}
        />
        <div className="flex-1 min-w-0">
          <p className={`${theme.typeTitleMedium} text-white`}>{payload.title}</p>
          {payload.description && (
            <p className={`${theme.typeBodySmall} text-ask-secondary mt-0.5`}>{payload.description}</p>
          )}
        </div>
      </div>

      {showCustom ? (
        <div className="flex gap-2">
          <input
            autoFocus
            type="text"
            value={customText}
            onChange={e => setCustomText(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter' && customText.trim()) respond(customText.trim()) }}
            placeholder="Custom reply…"
            className={theme.input}
          />
          <button onClick={() => setShowCustom(false)} className={theme.btnText}>
            Cancel
          </button>
        </div>
      ) : theme.isAndroid ? (
        // Android M3: separate filled-tonal (first) + outlined (rest) pill buttons
        <div className="flex flex-col gap-2">
          {payload.options.map((opt, i) => (
            <button
              key={opt}
              onClick={() => respond(opt)}
              className={i === 0 ? theme.optionBtnPrimary : theme.optionBtnSecondary}
            >
              {opt}
            </button>
          ))}
          {payload.allow_custom && (
            <button onClick={() => setShowCustom(true)} className={theme.btnOutlined}>
              Other…
            </button>
          )}
        </div>
      ) : (
        // iOS: inset-grouped table view — rounded container, options with hairline dividers
        <div className={theme.optionContainer}>
          {payload.options.map(opt => (
            <button key={opt} onClick={() => respond(opt)} className={theme.optionBtnPrimary}>
              {opt}
            </button>
          ))}
          {payload.allow_custom && (
            <button onClick={() => setShowCustom(true)} className={theme.optionBtnSecondary}>
              Other…
            </button>
          )}
        </div>
      )}
    </div>
  )
}
