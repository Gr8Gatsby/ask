import { useState } from 'react'
import type { Block, StartSessionPayload } from '../../lib/types'

interface Props {
  block: Block
  payload: StartSessionPayload
  onRespond: (blockID: string, value: string) => void
}

export default function StartSessionBlock({ block, payload, onRespond }: Props) {
  const [open, setOpen] = useState(false)

  return (
    <>
      <button
        onClick={() => setOpen(true)}
        className="flex items-center gap-2 text-ask-blue text-sm font-semibold hover:opacity-80 transition-opacity"
      >
        <span className="text-lg leading-none">+</span>
        Start Session
      </button>

      {open && (
        <div className="fixed inset-0 bg-black/60 z-50 flex items-end justify-center" onClick={() => setOpen(false)}>
          <div className="w-full max-w-[390px] bg-ask-card rounded-t-2xl p-4 pb-8" onClick={e => e.stopPropagation()}>
            <div className="w-10 h-1 rounded-full bg-ask-sep mx-auto mb-4" />
            <p className="text-sm font-semibold text-ask-text mb-3">Choose a repository</p>
            <div className="flex flex-col gap-0">
              {payload.repos.map(repo => (
                <button
                  key={repo.path}
                  onClick={() => { onRespond(block.blockID, repo.path); setOpen(false) }}
                  className="flex items-center gap-3 py-3 border-b border-ask-sep last:border-0 hover:bg-ask-text/[0.05] transition-colors text-left"
                >
                  <span className="text-base">📁</span>
                  <div>
                    <p className="text-sm text-ask-text">{repo.name}</p>
                    <p className="text-[10px] text-ask-secondary font-mono">{repo.path}</p>
                  </div>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </>
  )
}
