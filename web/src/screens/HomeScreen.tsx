import { useNavigate } from 'react-router-dom'
import type { Block, TilePayload } from '../lib/types'
import { useBlocks } from '../lib/useBlocks'
import ActionQueueCard from '../components/ActionQueueCard'
import ScriptIcon from '../components/shared/ScriptIcon'

// ---- Tile grid card (Recent section) ----

const DOT: Record<string, string> = {
  green: 'bg-ask-green', blue: 'bg-ask-blue', orange: 'bg-ask-orange',
  red: 'bg-ask-red', yellow: 'bg-ask-yellow',
}

function TileCard({ scriptID, blocks, onClick }: { scriptID: string; blocks: Block[]; onClick: () => void }) {
  const first = blocks[0]
  let tile: TilePayload | null = null
  try { tile = JSON.parse(blocks.find(b => b.blockType === 'tile')?.payload ?? 'null') } catch { /* */ }

  return (
    <button
      onClick={onClick}
      className={`w-full text-left bg-ask-card rounded-xl p-3 border ${tile?.action_required ? 'border-ask-orange/60' : 'border-transparent'} hover:bg-ask-card2 transition-colors`}
    >
      <div className="flex items-center gap-2 mb-1.5">
        <ScriptIcon
          scriptIconData={first.scriptIconData}
          scriptIconSVG={first.scriptIconSVG}
          scriptIcon={first.scriptIcon}
          scriptName={first.scriptName}
          size={22}
        />
        <span className="text-xs font-semibold text-white truncate">{first.scriptName}</span>
        {tile?.action_required && <div className="w-2 h-2 rounded-full bg-ask-orange ml-auto flex-shrink-0" />}
      </div>
      {tile && (
        <>
          <div className="flex items-center gap-1.5">
            <div className={`w-1.5 h-1.5 rounded-full ${DOT[tile.status_color ?? ''] ?? 'bg-ask-secondary'}`} />
            <span className="text-xs text-ask-secondary">{tile.label}</span>
          </div>
          {tile.body && <p className="text-[11px] text-ask-secondary/70 mt-1 truncate">{tile.body}</p>}
        </>
      )}
    </button>
  )
}

// ---- Screen ----

export default function HomeScreen() {
  const { scriptGroups, loading, error, respond } = useBlocks()
  const navigate = useNavigate()

  if (loading) {
    return <div className="flex items-center justify-center h-full text-ask-secondary text-sm">Connecting to MockAskMac…</div>
  }
  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full gap-3 p-6 text-center">
        <p className="text-ask-red font-semibold text-sm">MockAskMac not running</p>
        <p className="text-ask-secondary text-xs">Run <code className="font-mono bg-ask-card px-1.5 py-0.5 rounded">npm run dev</code> in ask/web/</p>
      </div>
    )
  }

  // Split groups: those with any showsInInbox block go into "Needs Response"
  const entries = Object.entries(scriptGroups)
  const needsResponseGroups = entries.filter(([, blocks]) => blocks.some(b => b.showsInInbox === 1))
  const recentGroups = entries.filter(([, blocks]) => !blocks.some(b => b.showsInInbox === 1))

  return (
    <div className="flex flex-col h-full">
      {/* Nav bar */}
      <div className="flex items-center justify-between px-4 pt-12 pb-2">
        <h1 className="text-xl font-bold text-white">Ask</h1>
        <span className="text-xs text-ask-secondary">MockAskMac</span>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar px-4 pb-4 flex flex-col gap-5">
        {/* Needs Response */}
        {needsResponseGroups.length > 0 && (
          <section className="flex flex-col gap-2">
            <p className="text-xs font-semibold text-ask-secondary uppercase tracking-wide">Needs Response</p>
            {needsResponseGroups.map(([scriptID, blocks]) => (
              <ActionQueueCard
                key={scriptID}
                scriptID={scriptID}
                blocks={blocks}
                onRespond={respond}
              />
            ))}
          </section>
        )}

        {/* Recent */}
        {recentGroups.length > 0 && (
          <section className="flex flex-col gap-2">
            {needsResponseGroups.length > 0 && (
              <p className="text-xs font-semibold text-ask-secondary uppercase tracking-wide">Recent</p>
            )}
            <div className="grid grid-cols-2 gap-2">
              {recentGroups.map(([scriptID, blocks]) => (
                <TileCard
                  key={scriptID}
                  scriptID={scriptID}
                  blocks={blocks}
                  onClick={() => navigate(`/script/${scriptID}`)}
                />
              ))}
            </div>
          </section>
        )}

        {entries.length === 0 && (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No active scripts</div>
        )}
      </div>
    </div>
  )
}
