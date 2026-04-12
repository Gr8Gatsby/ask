import { useNavigate } from 'react-router-dom'
import type { Block, TilePayload, Urgency } from '../lib/types'
import { useBlocks } from '../lib/useBlocks'
import UrgencyBadge from '../components/shared/UrgencyBadge'
import ScriptIcon from '../components/shared/ScriptIcon'

function urgencyColor(urgency?: Urgency) {
  return urgency === 'urgent' ? 'border-ask-red' : urgency === 'info' ? 'border-ask-secondary/40' : 'border-ask-orange'
}

function TileView({ scriptID, blocks, onClick }: { scriptID: string; blocks: Block[]; onClick: () => void }) {
  const tileBlock = blocks.find(b => b.blockType === 'tile')
  const first = blocks[0]
  const tile = tileBlock ? JSON.parse(tileBlock.payload) as TilePayload : null
  const hasAction = tile?.action_required

  const dotColor = tile?.status_color === 'green' ? 'bg-ask-green'
    : tile?.status_color === 'blue' ? 'bg-ask-blue'
    : tile?.status_color === 'red' ? 'bg-ask-red'
    : tile?.status_color === 'orange' ? 'bg-ask-orange'
    : tile?.status_color === 'yellow' ? 'bg-ask-yellow'
    : 'bg-ask-secondary'

  return (
    <button
      onClick={onClick}
      className={`w-full text-left bg-ask-card rounded-xl p-3 flex flex-col gap-1.5 border ${hasAction ? 'border-ask-orange' : 'border-transparent'} hover:bg-ask-card2 transition-colors active:scale-[0.98]`}
    >
      <div className="flex items-center gap-2">
        <ScriptIcon
          scriptIconData={first.scriptIconData}
          scriptIconSVG={first.scriptIconSVG}
          scriptIcon={first.scriptIcon}
          scriptName={first.scriptName}
          size={22}
        />
        <span className="text-xs font-semibold text-white truncate flex-1">{first.scriptName}</span>
        {hasAction && <div className="w-2 h-2 rounded-full bg-ask-orange" />}
      </div>
      {tile && (
        <>
          <div className="flex items-center gap-1.5">
            <div className={`w-1.5 h-1.5 rounded-full ${dotColor}`} />
            <span className="text-xs text-ask-secondary">{tile.label}</span>
          </div>
          {tile.body && <p className="text-[11px] text-ask-secondary leading-relaxed truncate">{tile.body}</p>}
        </>
      )}
      <p className="text-[10px] text-ask-secondary/60">{scriptID}</p>
    </button>
  )
}

export default function HomeScreen() {
  const { scriptGroups, needsResponse, loading, error, respond } = useBlocks()
  const navigate = useNavigate()

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full text-ask-secondary text-sm">
        Connecting to MockAskMac...
      </div>
    )
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center h-full gap-3 p-6 text-center">
        <p className="text-ask-red font-semibold text-sm">MockAskMac not running</p>
        <p className="text-ask-secondary text-xs">Start it with <code className="font-mono bg-ask-card px-1.5 py-0.5 rounded">npm run dev</code></p>
      </div>
    )
  }

  return (
    <div className="flex flex-col h-full">
      {/* Navigation bar */}
      <div className="flex items-center justify-between px-4 pt-12 pb-3">
        <h1 className="text-xl font-bold text-white">Ask</h1>
        <span className="text-xs text-ask-secondary">MockAskMac</span>
      </div>

      {/* Needs-response alert chips */}
      {needsResponse.length > 0 && (
        <div className="px-4 mb-3 flex flex-col gap-1.5">
          {needsResponse
            .filter(b => !['agent_session', 'start_session', 'tile'].includes(b.blockType))
            .map(block => {
              const p = JSON.parse(block.payload) as { title?: string; urgency?: Urgency }
              return (
                <button
                  key={block.blockID}
                  onClick={() => navigate(`/script/${block.scriptID}`)}
                  className={`flex items-center gap-2 bg-ask-card rounded-lg px-3 py-2 border ${urgencyColor(p.urgency)} hover:bg-ask-card2 transition-colors`}
                >
                  <UrgencyBadge urgency={p.urgency ?? 'warning'} />
                  <span className="text-xs font-medium text-white truncate flex-1">{p.title ?? block.blockType}</span>
                  <span className="text-[10px] text-ask-secondary">{block.scriptName}</span>
                </button>
              )
            })}
        </div>
      )}

      {/* Script tile grid */}
      <div className="flex-1 overflow-y-auto no-scrollbar px-4 pb-4">
        {Object.keys(scriptGroups).length === 0 ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">
            No active scripts
          </div>
        ) : (
          <div className="grid grid-cols-2 gap-3">
            {Object.entries(scriptGroups).map(([scriptID, blocks]) => (
              <TileView
                key={scriptID}
                scriptID={scriptID}
                blocks={blocks}
                onClick={() => navigate(`/script/${scriptID}`)}
              />
            ))}
          </div>
        )}
      </div>

      {/* Suppress unused respond warning */}
      <div style={{ display: 'none' }}>{String(typeof respond)}</div>
    </div>
  )
}
