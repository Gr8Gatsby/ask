import type { IconCardPayload } from '../../lib/types'

interface Props { payload: IconCardPayload }

export default function IconCardBlock({ payload }: Props) {
  return (
    <div className="flex items-center gap-3">
      <div className="w-10 h-10 rounded-xl bg-ask-card2 flex items-center justify-center flex-shrink-0">
        <span className="text-xl">📋</span>
      </div>
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-white leading-tight">{payload.title}</p>
        {payload.subtitle && (
          <p className="text-xs text-ask-secondary mt-0.5 truncate">{payload.subtitle}</p>
        )}
      </div>
    </div>
  )
}
