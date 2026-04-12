import type { CompactSummaryPayload } from '../../lib/types'
import Markdown from '../shared/Markdown'

interface Props { payload: CompactSummaryPayload }

export default function CompactSummaryBlock({ payload }: Props) {
  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center gap-2">
        <span className="text-[10px] font-bold text-ask-secondary uppercase tracking-wide">{payload.project}</span>
        {payload.trigger && (
          <span className="text-[10px] text-ask-secondary/60">· {payload.trigger}</span>
        )}
      </div>
      <div className="text-xs text-ask-secondary leading-relaxed line-clamp-4">
        <Markdown>{payload.summary}</Markdown>
      </div>
    </div>
  )
}
