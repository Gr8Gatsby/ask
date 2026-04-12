import { createContext, useContext, useState } from 'react'

export type Platform = 'ios' | 'android'

interface PlatformContextType {
  platform: Platform
  setPlatform: (p: Platform) => void
}

const PlatformContext = createContext<PlatformContextType>({
  platform: 'ios',
  setPlatform: () => {},
})

export function PlatformProvider({ children }: { children: React.ReactNode }) {
  const [platform, setPlatformState] = useState<Platform>(() => {
    return (localStorage.getItem('ask-platform') as Platform) ?? 'ios'
  })

  function setPlatform(p: Platform) {
    setPlatformState(p)
    localStorage.setItem('ask-platform', p)
  }

  return (
    <PlatformContext.Provider value={{ platform, setPlatform }}>
      {children}
    </PlatformContext.Provider>
  )
}

export function usePlatform() {
  return useContext(PlatformContext)
}

// Structural theme helpers — colors come from CSS vars, these cover shapes/borders
export function useTheme() {
  const { platform } = usePlatform()
  const md = platform === 'android'

  return {
    platform,
    isAndroid: md,

    // Card: border on iOS, elevation shadow on Android
    card: md
      ? 'bg-ask-card rounded-2xl shadow-md shadow-black/50'
      : 'bg-ask-card rounded-xl border border-ask-sep/50',

    // Default option button (e.g. confirmation options, quick-reply options)
    buttonOption: md
      ? 'rounded-full border border-ask-sep bg-ask-card2 text-white hover:bg-ask-blue/20 hover:border-ask-blue/40 hover:text-ask-blue transition-colors'
      : 'rounded-xl bg-ask-card2 text-white hover:bg-ask-blue hover:text-white transition-colors',

    // Allow / positive action
    buttonAllow: md
      ? 'rounded-full bg-ask-green/20 text-ask-green border border-ask-green/30 hover:bg-ask-green/30 transition-colors'
      : 'rounded-xl bg-ask-green/15 text-ask-green border border-ask-green/30 hover:bg-ask-green/25 transition-colors',

    // Deny / destructive
    buttonDeny: md
      ? 'rounded-full bg-ask-orange/20 text-ask-orange border border-ask-orange/30 hover:bg-ask-orange/30 transition-colors'
      : 'rounded-xl bg-ask-orange/15 text-ask-orange border border-ask-orange/30 hover:bg-ask-orange/25 transition-colors',

    // Neutral / cancel
    buttonNeutral: md
      ? 'rounded-full bg-ask-card2 text-white hover:bg-ask-card2/80 transition-colors'
      : 'rounded-xl bg-ask-card2 text-white hover:bg-ask-card2/80 transition-colors',

    // Primary CTA (send, submit)
    buttonPrimary: md
      ? 'rounded-full bg-ask-blue text-white font-medium hover:opacity-90 transition-opacity'
      : 'rounded-xl bg-ask-blue text-white font-semibold hover:opacity-90 transition-opacity',

    // Chip (alert chips, badges)
    chip: md ? 'rounded-lg' : 'rounded-full',
  }
}
