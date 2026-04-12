import type { AlertPayload } from '../../lib/types'
import UrgencyBadge from '../shared/UrgencyBadge'

interface Props { payload: AlertPayload }

export default function AlertBlock({ payload }: Props) {
  return (
    <div className="flex items-start gap-2">
      <UrgencyBadge urgency={payload.urgency ?? 'info'} />
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-white leading-snug">{payload.title}</p>
        {payload.body && <p className="text-xs text-ask-secondary mt-0.5 leading-relaxed">{payload.body}</p>}
      </div>
    </div>
  )
}
