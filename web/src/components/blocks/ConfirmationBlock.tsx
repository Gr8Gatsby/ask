import type { Block, ConfirmationPayload } from '../../lib/types'
import { useTheme, PlatformIcon } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: ConfirmationPayload
  onRespond: (blockID: string, value: string) => void
}

// Permission/Bash block — "Permission needed" for shell commands
function PermissionBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const denyWords = ['deny', 'cancel', 'no', 'reject']
  const allowWords = ['allow', 'yes', 'approve', 'permit']

  function classify(opt: string) {
    const l = opt.toLowerCase()
    if (denyWords.some(w => l.includes(w))) return 'deny'
    if (allowWords.some(w => l.includes(w))) return 'allow'
    return 'neutral'
  }

  return (
    <div className="flex flex-col gap-3">
      {/* Header — orange warning label */}
      <div className="flex items-center gap-1.5">
        <PlatformIcon ios="⚠" android="security" fill size={theme.isAndroid ? 18 : 14} className="text-ask-orange" />
        <span className={`${theme.sectionHeader} text-ask-orange`}>Permission needed</span>
      </div>

      <p className={`${theme.typeTitleMedium} text-white`}>{payload.title}</p>

      {payload.body && (
        <p className={`${theme.typeBodyMedium} text-ask-secondary`}>{payload.body}</p>
      )}

      {payload.command && (
        <div className={`${theme.isAndroid ? 'rounded-2xl' : 'rounded-xl'} bg-black/50 border border-ask-sep/40 px-3 py-2.5`}>
          <p className={`${theme.typeLabelMedium} text-ask-secondary mb-1.5`}>
            {theme.isAndroid ? 'Command' : 'Bash wants to run:'}
          </p>
          <pre className="text-xs font-mono text-white whitespace-pre-wrap break-all leading-relaxed">
            {payload.command}
          </pre>
        </div>
      )}

      <div className={`flex flex-col gap-2 ${theme.isAndroid ? 'mt-1' : ''}`}>
        {payload.options.map(opt => {
          const kind = classify(opt)
          return (
            <button
              key={opt}
              onClick={() => onRespond(block.blockID, opt)}
              className={
                kind === 'allow' ? theme.btnAllow
                : kind === 'deny' ? theme.btnDeny
                : theme.isAndroid ? theme.btnOutlined : theme.btnOutlined
              }
            >
              {opt}
            </button>
          )
        })}
      </div>
    </div>
  )
}

// Standard confirmation block
export default function ConfirmationBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()

  if (payload.command) {
    return <PermissionBlock block={block} payload={payload} onRespond={onRespond} />
  }

  const urgency = payload.urgency ?? 'warning'
  const urgencyIcon = urgency === 'urgent'
    ? { ios: '⚠', android: 'error', color: 'text-ask-red' }
    : urgency === 'info'
    ? { ios: 'ℹ', android: 'info', color: 'text-ask-blue' }
    : { ios: '⚠', android: 'warning', color: 'text-ask-orange' }

  const inline = payload.options.length <= 2

  return (
    <div className="flex flex-col gap-3">
      {/* Title row with urgency icon */}
      <div className="flex items-start gap-2">
        <PlatformIcon
          ios={urgencyIcon.ios}
          android={urgencyIcon.android}
          fill
          size={theme.isAndroid ? 20 : 16}
          className={`flex-shrink-0 mt-0.5 ${urgencyIcon.color}`}
        />
        <div className="flex-1 min-w-0">
          <p className={`${theme.typeTitleMedium} text-white leading-snug`}>{payload.title}</p>
          {payload.body && (
            <p className={`${theme.typeBodyMedium} text-ask-secondary mt-0.5`}>{payload.body}</p>
          )}
        </div>
      </div>

      {/* Buttons */}
      {theme.isAndroid ? (
        // M3: inline row for ≤2 options, stacked for more
        <div className={inline ? 'flex gap-2 justify-end' : 'flex flex-col gap-2'}>
          {payload.options.map((opt, i) => (
            <button
              key={opt}
              onClick={() => onRespond(block.blockID, opt)}
              className={
                inline
                  ? (i === payload.options.length - 1 ? theme.btnTonal : theme.btnText)
                  : (i === 0 ? theme.btnFilled : theme.btnOutlined)
              }
            >
              {opt}
            </button>
          ))}
        </div>
      ) : (
        // iOS: inset-grouped cell style — rounded container with hairline dividers
        <div className={theme.optionContainer}>
          {payload.options.map(opt => (
            <button key={opt} onClick={() => onRespond(block.blockID, opt)} className={theme.optionBtnPrimary}>
              {opt}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
