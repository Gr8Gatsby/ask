import type { Block, ConfirmationPayload } from '../../lib/types'
import UrgencyBadge from '../shared/UrgencyBadge'

interface Props {
  block: Block
  payload: ConfirmationPayload
  onRespond: (blockID: string, value: string) => void
}

export default function ConfirmationBlock({ block, payload, onRespond }: Props) {
  const inline = payload.options.length <= 2

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-start gap-2">
        <UrgencyBadge urgency={payload.urgency ?? 'warning'} />
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
            className={`${inline ? 'flex-1' : 'w-full'} py-2 px-3 rounded-lg bg-ask-card2 text-sm font-medium text-white hover:bg-ask-blue hover:text-white transition-colors active:scale-[0.98]`}
          >
            {opt}
          </button>
        ))}
      </div>
    </div>
  )
}
