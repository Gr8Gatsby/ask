import { createContext, useContext, useState } from 'react'

interface SettingsContextType {
  useBrandColors: boolean
  setUseBrandColors: (v: boolean) => void
  showDebugInfo: boolean
  setShowDebugInfo: (v: boolean) => void
}

const Ctx = createContext<SettingsContextType>({
  useBrandColors: true,
  setUseBrandColors: () => {},
  showDebugInfo: false,
  setShowDebugInfo: () => {},
})

export function SettingsProvider({ children }: { children: React.ReactNode }) {
  const [useBrandColors, setUseBrandColorsState] = useState<boolean>(() =>
    (localStorage.getItem('ask-brand-colors') ?? 'true') === 'true'
  )
  const [showDebugInfo, setShowDebugInfoState] = useState<boolean>(() =>
    localStorage.getItem('ask-debug-info') === 'true'
  )

  function setUseBrandColors(v: boolean) {
    setUseBrandColorsState(v)
    localStorage.setItem('ask-brand-colors', String(v))
  }
  function setShowDebugInfo(v: boolean) {
    setShowDebugInfoState(v)
    localStorage.setItem('ask-debug-info', String(v))
  }

  return (
    <Ctx.Provider value={{ useBrandColors, setUseBrandColors, showDebugInfo, setShowDebugInfo }}>
      {children}
    </Ctx.Provider>
  )
}

export function useSettings() { return useContext(Ctx) }
