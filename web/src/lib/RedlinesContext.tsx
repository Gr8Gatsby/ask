import { createContext, useContext, useState } from 'react'

interface RedlinesCtx {
  showRedlines: boolean
  setShowRedlines: (v: boolean) => void
  focusedBlockID: string | null
  setFocusedBlockID: (id: string | null) => void
  inspectorOpen: boolean
  setInspectorOpen: (v: boolean) => void
  showSpacing: boolean
  setShowSpacing: (v: boolean) => void
  showAllDims: boolean
  setShowAllDims: (v: boolean) => void
}

const RedlinesContext = createContext<RedlinesCtx>({
  showRedlines: false, setShowRedlines: () => {},
  focusedBlockID: null, setFocusedBlockID: () => {},
  inspectorOpen: false, setInspectorOpen: () => {},
  showSpacing: false, setShowSpacing: () => {},
  showAllDims: false, setShowAllDims: () => {},
})

export function RedlinesProvider({ children }: { children: React.ReactNode }) {
  const [showRedlines, setShowRedlines] = useState(false)
  const [focusedBlockID, setFocusedBlockID] = useState<string | null>(null)
  const [inspectorOpen, setInspectorOpen] = useState(false)
  const [showSpacing, setShowSpacing] = useState(false)
  const [showAllDims, setShowAllDims] = useState(false)
  return (
    <RedlinesContext.Provider value={{
      showRedlines, setShowRedlines,
      focusedBlockID, setFocusedBlockID,
      inspectorOpen, setInspectorOpen,
      showSpacing, setShowSpacing,
      showAllDims, setShowAllDims,
    }}>
      {children}
    </RedlinesContext.Provider>
  )
}

export function useRedlines() { return useContext(RedlinesContext) }
