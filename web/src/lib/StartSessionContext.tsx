import { createContext, useContext, useState } from 'react'
import type { Block, StartSessionPayload } from './types'

export interface StartSessionAction {
  block: Block
  payload: StartSessionPayload
  respond: (blockID: string, value: string) => void
}

interface Ctx {
  action: StartSessionAction | null
  setAction: (a: StartSessionAction | null) => void
}

const StartSessionCtx = createContext<Ctx>({ action: null, setAction: () => {} })

export function StartSessionProvider({ children }: { children: React.ReactNode }) {
  const [action, setAction] = useState<StartSessionAction | null>(null)
  return <StartSessionCtx.Provider value={{ action, setAction }}>{children}</StartSessionCtx.Provider>
}

export function useStartSession() { return useContext(StartSessionCtx) }
