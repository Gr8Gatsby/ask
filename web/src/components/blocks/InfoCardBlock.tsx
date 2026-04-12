import type { InfoCardPayload } from '../../lib/types'

interface Props { payload: InfoCardPayload }

export default function InfoCardBlock({ payload }: Props) {
  return (
    <div className="flex flex-col gap-1.5">
      <p className="text-sm font-semibold text-ask-text">{payload.title}</p>
      <div className="border-t border-ask-sep pt-1.5 flex flex-col gap-1">
        {payload.pairs.map((pair, i) => (
          <div key={i} className="flex gap-3">
            <span className="text-xs text-ask-secondary w-20 flex-shrink-0">{pair.key}</span>
            <span className="text-xs text-ask-text font-medium">{pair.value}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
