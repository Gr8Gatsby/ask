import { createContext, useContext, useState } from 'react'

interface SettingsContextType {
  useBrandColors: boolean
  setUseBrandColors: (v: boolean) => void
  selectedMachineID: string | null
  setSelectedMachineID: (id: string | null) => void
}

const Ctx = createContext<SettingsContextType>({
  useBrandColors: true,
  setUseBrandColors: () => {},
  selectedMachineID: null,
  setSelectedMachineID: () => {},
})

export function SettingsProvider({ children }: { children: React.ReactNode }) {
  const [useBrandColors, setUseBrandColorsState] = useState<boolean>(() =>
    (localStorage.getItem('ask-brand-colors') ?? 'true') === 'true'
  )
  const [selectedMachineID, setSelectedMachineIDState] = useState<string | null>(() =>
    localStorage.getItem('ask-selected-machine') ?? null
  )

  function setUseBrandColors(v: boolean) {
    setUseBrandColorsState(v)
    localStorage.setItem('ask-brand-colors', String(v))
  }
  function setSelectedMachineID(id: string | null) {
    setSelectedMachineIDState(id)
    if (id === null) localStorage.removeItem('ask-selected-machine')
    else localStorage.setItem('ask-selected-machine', id)
  }

  return (
    <Ctx.Provider value={{ useBrandColors, setUseBrandColors, selectedMachineID, setSelectedMachineID }}>
      {children}
    </Ctx.Provider>
  )
}

export function useSettings() { return useContext(Ctx) }
