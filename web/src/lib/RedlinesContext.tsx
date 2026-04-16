import { createContext, useContext, useState } from 'react'

interface RedlinesCtx {
  showRedlines: boolean
  setShowRedlines: (v: boolean) => void
  focusedBlockID: string | null
  setFocusedBlockID: (id: string | null) => void
  inspectorOpen: boolean
  setInspectorOpen: (v: boolean) => void
}

const RedlinesContext = createContext<RedlinesCtx>({
  showRedlines: false, setShowRedlines: () => {},
  focusedBlockID: null, setFocusedBlockID: () => {},
  inspectorOpen: false, setInspectorOpen: () => {},
})

export function RedlinesProvider({ children }: { children: React.ReactNode }) {
  const [showRedlines, setShowRedlines] = useState(false)
  const [focusedBlockID, setFocusedBlockID] = useState<string | null>(null)
  const [inspectorOpen, setInspectorOpen] = useState(false)
  return (
    <RedlinesContext.Provider value={{ showRedlines, setShowRedlines, focusedBlockID, setFocusedBlockID, inspectorOpen, setInspectorOpen }}>
      {children}
    </RedlinesContext.Provider>
  )
}

export function useRedlines() { return useContext(RedlinesContext) }
