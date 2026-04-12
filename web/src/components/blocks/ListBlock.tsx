import type { Block, ListPayload } from '../../lib/types'

interface Props {
  block: Block
  payload: ListPayload
  onRespond: (blockID: string, value: string) => void
}

export default function ListBlock({ block, payload, onRespond }: Props) {
  return (
    <div className="flex flex-col gap-2">
      {payload.title && <p className="text-sm font-semibold text-ask-text">{payload.title}</p>}
      <div className="border-t border-ask-sep">
        {payload.items.map(item => (
          <button
            key={item.id}
            onClick={() => onRespond(block.blockID, item.id)}
            className="w-full flex items-center justify-between py-2.5 border-b border-ask-sep last:border-0 hover:bg-ask-text/[0.05] transition-colors text-left px-0.5"
          >
            <div>
              <p className="text-sm text-ask-text">{item.label}</p>
              {item.subtitle && <p className="text-xs text-ask-secondary">{item.subtitle}</p>}
            </div>
            <span className="text-ask-secondary text-sm">›</span>
          </button>
        ))}
      </div>
      {payload.actions && payload.actions.length > 0 && (
        <div className="flex flex-col gap-2 pt-1">
          {payload.actions.map(action => (
            <button
              key={action}
              onClick={() => onRespond(block.blockID, action)}
              className="w-full py-2 rounded-lg bg-ask-card2 text-sm font-medium text-ask-text hover:bg-ask-card2/60 transition-colors"
            >
              {action}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}
