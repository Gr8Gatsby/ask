import type { Block, ConfirmationPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: ConfirmationPayload
  onRespond: (blockID: string, value: string) => void
}

// Permission-style block — matches iOS "Permission needed" layout
function PermissionBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()
  const denyOptions = ['Deny', 'Cancel', 'No', 'Reject']
  const allowOptions = ['Allow', 'Yes', 'Approve', 'Permit']

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center gap-2">
        <span className="text-xs font-bold text-ask-orange uppercase tracking-wide">Permission needed</span>
      </div>
      <p className="text-sm font-semibold text-white">{payload.title}</p>
      {payload.body && (
        <p className="text-xs text-ask-secondary leading-relaxed">{payload.body}</p>
      )}
      {payload.command && (
        <div className="bg-black/40 rounded-lg px-3 py-2.5 border border-ask-sep">
          <p className="text-[10px] text-ask-secondary mb-1">Bash wants to run:</p>
          <pre className="text-xs text-white font-mono whitespace-pre-wrap break-all leading-relaxed">
            {payload.command}
          </pre>
        </div>
      )}
      <div className="flex flex-col gap-2">
        {payload.options.map(opt => {
          const isDeny = denyOptions.some(d => opt.toLowerCase().includes(d.toLowerCase()))
          const isAllow = allowOptions.some(a => opt.toLowerCase().includes(a.toLowerCase()))
          return (
            <button
              key={opt}
              onClick={() => onRespond(block.blockID, opt)}
              className={`w-full py-2.5 px-3 text-sm font-semibold active:scale-[0.98] ${
                isDeny ? theme.buttonDeny
                : isAllow ? theme.buttonAllow
                : theme.buttonNeutral
              }`}
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

  const inline = payload.options.length <= 2

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-start gap-2">
        <span className={`font-mono text-[10px] font-bold px-1 py-0.5 rounded flex-shrink-0 ${
          payload.urgency === 'urgent'
            ? 'text-ask-red bg-ask-red/15'
            : payload.urgency === 'info'
            ? 'text-ask-secondary bg-ask-secondary/15'
            : 'text-ask-orange bg-ask-orange/15'
        }`}>
          {payload.urgency === 'urgent' ? '[!]' : payload.urgency === 'info' ? '[i]' : '[~]'}
        </span>
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-white leading-snug">{payload.title}</p>
          {payload.body && <p className="text-xs text-ask-secondary mt-0.5 leading-relaxed">{payload.body}</p>}
        </div>
      </div>
      <div className={inline ? 'flex gap-2' : 'flex flex-col gap-2'}>
        {payload.options.map(opt => (
          <button
            key={opt}
            onClick={() => onRespond(block.blockID, opt)}
            className={`${inline ? 'flex-1' : 'w-full'} py-2 px-3 text-sm font-medium active:scale-[0.98] ${theme.buttonOption}`}
          >
            {opt}
          </button>
        ))}
      </div>
    </div>
  )
}
