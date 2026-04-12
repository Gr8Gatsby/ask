import type { ActivityFeedPayload } from '../../lib/types'

interface Props { payload: ActivityFeedPayload }

const TOOL_ICONS: Record<string, string> = {
  Edit: '✏', Write: '📝', Read: '📖', Bash: '⚡', Glob: '🔍',
  Grep: '🔎', Agent: '🤖', WebFetch: '🌐', WebSearch: '🌐',
}

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime()
  const m = Math.floor(diff / 60_000)
  if (m < 1) return 'just now'
  if (m < 60) return `${m}m ago`
  return `${Math.floor(m / 60)}h ago`
}

export default function ActivityFeedBlock({ payload }: Props) {
  return (
    <div>
      <p className="text-xs font-semibold text-ask-secondary mb-2">{payload.project} · activity</p>
      <div className="flex flex-col gap-1.5">
        {payload.entries.map((entry, i) => (
          <div key={i} className="flex items-center gap-2">
            <span className="text-xs w-4 text-center flex-shrink-0">{TOOL_ICONS[entry.tool] ?? '⚙'}</span>
            <span className="text-xs font-mono text-ask-blue flex-shrink-0">{entry.tool}</span>
            <span className="text-xs text-ask-secondary truncate flex-1">{entry.preview}</span>
            <span className="text-[10px] text-ask-secondary/60 flex-shrink-0">{relativeTime(entry.timestamp)}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
