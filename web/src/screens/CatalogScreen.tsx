import { useState } from 'react'
import { CATALOG_FIXTURES } from '../catalog/fixtures'
import BlockRenderer from '../components/blocks/BlockRenderer'

export default function CatalogScreen() {
  const [responded, setResponded] = useState<Record<string, string>>({})

  function handleRespond(blockID: string, value: string) {
    setResponded(prev => ({ ...prev, [blockID]: value }))
    // Reset after 2s so the block is interactive again in the catalog
    setTimeout(() => {
      setResponded(prev => {
        const next = { ...prev }
        delete next[blockID]
        return next
      })
    }, 2000)
  }

  return (
    <div className="flex flex-col h-full">
      <div className="px-4 pt-3 pb-3 border-b border-ask-sep">
        <h1 className="text-xl font-bold text-ask-text">Catalog</h1>
        <p className="text-xs text-ask-secondary mt-0.5">All block types with fixture data</p>
      </div>

      <div className="flex-1 overflow-y-auto no-scrollbar divide-y divide-ask-sep">
        {CATALOG_FIXTURES.map(({ label, block }) => (
          <div key={block.blockID} className="px-4 py-3">
            <p className="text-[10px] font-mono text-ask-secondary mb-2">{label}</p>
            {responded[block.blockID] ? (
              <div className="text-xs text-ask-green">
                ✓ Responded: "{responded[block.blockID]}"
              </div>
            ) : (
              <BlockRenderer block={block} onRespond={handleRespond} />
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
