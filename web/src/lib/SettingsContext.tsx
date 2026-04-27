import { createContext, useContext, useState } from 'react'

interface SettingsContextType {
  useBrandColors: boolean
  setUseBrandColors: (v: boolean) => void
  selectedMachineID: string | null
  setSelectedMachineID: (id: string | null) => void
  showBlockDebugInfo: boolean
  setShowBlockDebugInfo: (v: boolean) => void
  hiddenMachineIDs: Set<string>
  toggleHiddenMachine: (id: string) => void
}

const Ctx = createContext<SettingsContextType>({
  useBrandColors: true,
  setUseBrandColors: () => {},
  selectedMachineID: null,
  setSelectedMachineID: () => {},
  showBlockDebugInfo: false,
  setShowBlockDebugInfo: () => {},
  hiddenMachineIDs: new Set(),
  toggleHiddenMachine: () => {},
})

function loadHiddenMachineIDs(): Set<string> {
  const raw = localStorage.getItem('ask-hidden-machines') ?? ''
  return new Set(raw ? raw.split(',') : [])
}

export function SettingsProvider({ children }: { children: React.ReactNode }) {
  const [useBrandColors, setUseBrandColorsState] = useState<boolean>(() =>
    (localStorage.getItem('ask-brand-colors') ?? 'true') === 'true'
  )
  const [selectedMachineID, setSelectedMachineIDState] = useState<string | null>(() =>
    localStorage.getItem('ask-selected-machine') ?? null
  )
  const [showBlockDebugInfo, setShowBlockDebugInfoState] = useState<boolean>(() =>
    localStorage.getItem('ask-show-debug-info') === 'true'
  )
  const [hiddenMachineIDs, setHiddenMachineIDs] = useState<Set<string>>(loadHiddenMachineIDs)

  function setUseBrandColors(v: boolean) {
    setUseBrandColorsState(v)
    localStorage.setItem('ask-brand-colors', String(v))
  }
  function setSelectedMachineID(id: string | null) {
    setSelectedMachineIDState(id)
    if (id === null) localStorage.removeItem('ask-selected-machine')
    else localStorage.setItem('ask-selected-machine', id)
  }
  function setShowBlockDebugInfo(v: boolean) {
    setShowBlockDebugInfoState(v)
    localStorage.setItem('ask-show-debug-info', String(v))
  }
  function toggleHiddenMachine(id: string) {
    setHiddenMachineIDs(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id); else next.add(id)
      localStorage.setItem('ask-hidden-machines', [...next].join(','))
      return next
    })
  }

  return (
    <Ctx.Provider value={{
      useBrandColors, setUseBrandColors,
      selectedMachineID, setSelectedMachineID,
      showBlockDebugInfo, setShowBlockDebugInfo,
      hiddenMachineIDs, toggleHiddenMachine,
    }}>
      {children}
    </Ctx.Provider>
  )
}

export function useSettings() { return useContext(Ctx) }
