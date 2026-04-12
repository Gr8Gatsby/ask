import { useNavigate } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import type { FeedItemPayload } from '../lib/types'
import ScriptIcon from '../components/shared/ScriptIcon'

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

function relativeTime(iso: string) {
  const diff = Date.now() - new Date(iso).getTime()
  const m = Math.floor(diff / 60_000)
  if (m < 1) return 'just now'
  if (m < 60) return `${m}m ago`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ago`
  return `${Math.floor(h / 24)}d ago`
}

const DOT: Record<string, string> = {
  green: 'bg-ask-green', blue: 'bg-ask-blue', orange: 'bg-ask-orange',
  red: 'bg-ask-red', yellow: 'bg-ask-yellow',
}

export default function TaskFeedScreen() {
  const { blocks, loading } = useBlocks()
  const navigate = useNavigate()

  const feedBlocks = blocks
    .filter(b => b.blockType === 'feed_item')
    .slice()
    .sort((a, b) => {
      const ta = parsePayload<FeedItemPayload>(a.payload)?.timestamp ?? a.createdAt
      const tb = parsePayload<FeedItemPayload>(b.payload)?.timestamp ?? b.createdAt
      return new Date(tb).getTime() - new Date(ta).getTime()
    })

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 pt-12 pb-3 border-b border-ask-sep">
        <h1 className="text-xl font-bold text-white">Feed</h1>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar">
        {loading ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">Connecting…</div>
        ) : feedBlocks.length === 0 ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No feed entries</div>
        ) : (
          <div className="flex flex-col divide-y divide-ask-sep">
            {feedBlocks.map(block => {
              const p = parsePayload<FeedItemPayload>(block.payload)
              if (!p) return null
              const ts = p.timestamp ?? block.createdAt
              return (
                <button
                  key={block.blockID}
                  onClick={() => navigate(`/script/${block.scriptID}`)}
                  className="flex items-start gap-3 px-4 py-3.5 hover:bg-white/5 transition-colors text-left w-full"
                >
                  <ScriptIcon
                    scriptIconData={block.scriptIconData}
                    scriptIconSVG={block.scriptIconSVG}
                    scriptIcon={block.scriptIcon}
                    scriptName={block.scriptName}
                    size={28}
                  />
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-0.5">
                      <p className="text-sm text-white font-semibold truncate">{p.title}</p>
                      <div className={`w-1.5 h-1.5 rounded-full flex-shrink-0 ${DOT[p.color ?? ''] ?? 'bg-ask-secondary'}`} />
                    </div>
                    {p.body && <p className="text-xs text-ask-secondary truncate">{p.body}</p>}
                    <p className="text-[10px] text-ask-secondary/60 mt-0.5">{block.scriptName} · {relativeTime(ts)}</p>
                  </div>
                </button>
              )
            })}
          </div>
        )}
      </div>
    </div>
  )
}
