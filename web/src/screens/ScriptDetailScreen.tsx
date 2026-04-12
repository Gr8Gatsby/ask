import { useNavigate, useParams } from 'react-router-dom'
import { useBlocks } from '../lib/useBlocks'
import BlockRenderer from '../components/blocks/BlockRenderer'
import ScriptIcon from '../components/shared/ScriptIcon'

export default function ScriptDetailScreen() {
  const { scriptID } = useParams<{ scriptID: string }>()
  const navigate = useNavigate()
  const { scriptGroups, respond } = useBlocks()

  const blocks = (scriptID ? scriptGroups[scriptID] : []) ?? []
  const first = blocks[0]

  // Exclude tile blocks from the detail list (they're home-screen only)
  const visibleBlocks = blocks.filter(b => b.blockType !== 'tile')

  return (
    <div className="flex flex-col h-full">
      {/* Navigation bar */}
      <div className="flex items-center gap-3 px-4 pt-12 pb-3 border-b border-ask-sep">
        <button onClick={() => navigate(-1)} className="text-ask-blue text-sm">‹ Back</button>
        {first && (
          <div className="flex items-center gap-2 flex-1 min-w-0">
            <ScriptIcon
              scriptIconData={first.scriptIconData}
              scriptIconSVG={first.scriptIconSVG}
              scriptIcon={first.scriptIcon}
              scriptName={first.scriptName}
              size={24}
            />
            <span className="text-sm font-semibold text-white truncate">{first.scriptName}</span>
          </div>
        )}
      </div>

      {/* Block list */}
      <div className="flex-1 overflow-y-auto no-scrollbar">
        {visibleBlocks.length === 0 ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">
            No blocks
          </div>
        ) : (
          <div className="flex flex-col divide-y divide-ask-sep">
            {visibleBlocks.map(block => (
              <div key={block.blockID} className="px-4 py-3">
                <BlockRenderer block={block} onRespond={respond} />
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
