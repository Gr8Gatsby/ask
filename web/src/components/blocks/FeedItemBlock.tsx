import type { FeedItemPayload, StatusColor } from '../../lib/types'

const COLOR: Record<StatusColor, string> = {
  green:  'bg-ask-green',
  blue:   'bg-ask-blue',
  orange: 'bg-ask-orange',
  red:    'bg-ask-red',
  yellow: 'bg-ask-yellow',
}

interface Props { payload: FeedItemPayload }

export default function FeedItemBlock({ payload }: Props) {
  const dot = payload.color ? COLOR[payload.color] : 'bg-ask-secondary'

  return (
    <div className="flex items-start gap-2">
      <div className={`w-2 h-2 rounded-full mt-1.5 flex-shrink-0 ${dot}`} />
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-white">{payload.title}</p>
        {payload.body && <p className="text-xs text-ask-secondary mt-0.5">{payload.body}</p>}
      </div>
      {payload.timestamp && (
        <span className="text-[10px] text-ask-secondary flex-shrink-0">
          {new Date(payload.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
        </span>
      )}
    </div>
  )
}
