import type { StatusPayload, StatusColor } from '../../lib/types'

const DOT_COLOR: Record<StatusColor, string> = {
  green:  'bg-ask-green',
  blue:   'bg-ask-blue',
  orange: 'bg-ask-orange',
  red:    'bg-ask-red',
  yellow: 'bg-ask-yellow',
}

interface Props { payload: StatusPayload }

export default function StatusBlock({ payload }: Props) {
  const dot = payload.color ? DOT_COLOR[payload.color] : 'bg-ask-secondary'

  return (
    <div className="flex items-start gap-2">
      <div className={`w-2 h-2 rounded-full mt-1.5 flex-shrink-0 ${dot}`} />
      <div>
        <p className="text-sm font-semibold text-ask-text">{payload.label}</p>
        {payload.detail && <p className="text-xs text-ask-secondary mt-0.5">{payload.detail}</p>}
      </div>
    </div>
  )
}
