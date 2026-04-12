import type { Block, DetailPayload } from '../../lib/types'

interface Props {
  block: Block
  payload: DetailPayload
  onRespond: (blockID: string, value: string) => void
}

export default function DetailBlock({ block, payload, onRespond }: Props) {
  return (
    <div className="flex flex-col gap-3">
      <p className="text-sm font-semibold text-white">{payload.title}</p>
      <div className="border-t border-ask-sep pt-2">
        <p className="text-xs text-ask-secondary leading-relaxed whitespace-pre-wrap">{payload.body}</p>
      </div>
      {payload.actions && payload.actions.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {payload.actions.map(action => (
            <button
              key={action}
              onClick={() => onRespond(block.blockID, action)}
              className="flex-1 min-w-[80px] py-2 rounded-lg bg-ask-card2 text-sm font-medium text-white hover:bg-ask-blue hover:text-white transition-colors"
            >
              {action}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
