import type { SessionEventPayload } from '../../lib/types'

interface Props { payload: SessionEventPayload }

export default function SessionEventBlock({ payload }: Props) {
  const started = payload.event === 'started'
  return (
    <div className="flex items-center gap-2 py-1">
      <div className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${started ? 'bg-ask-green' : 'bg-ask-secondary'}`} />
      <span className="text-xs text-ask-secondary">
        {started ? 'Session started' : 'Session stopped'}
        {payload.project && <> · <span className="text-ask-text/70">{payload.project}</span></>}
      </span>
    </div>
  )
}
