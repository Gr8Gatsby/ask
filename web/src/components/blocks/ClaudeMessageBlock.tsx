import type { Block, ClaudeMessagePayload } from '../../lib/types'
import Markdown from '../shared/Markdown'

interface Props { block: Block; payload: ClaudeMessagePayload }

export default function ClaudeMessageBlock({ block: _block, payload }: Props) {
  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center gap-1.5">
        <div className="w-5 h-5 rounded-full bg-[#74AA9C] flex items-center justify-center text-[9px] font-bold text-white">C</div>
        <span className="text-xs font-medium text-ask-secondary">Claude Code</span>
      </div>
      <div className="border-t border-ask-sep pt-2">
        <Markdown>{payload.text}</Markdown>
      </div>
    </div>
  )
}
