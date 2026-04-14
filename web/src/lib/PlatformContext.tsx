import { createContext, useContext, useState } from 'react'
import { CaretLeft } from '@phosphor-icons/react'

export type Platform = 'ios' | 'android'
export type ThemeMode = 'dark' | 'light'

interface PlatformContextType {
  platform: Platform
  setPlatform: (p: Platform) => void
  themeMode: ThemeMode
  setThemeMode: (t: ThemeMode) => void
}

const Ctx = createContext<PlatformContextType>({
  platform: 'ios',
  setPlatform: () => {},
  themeMode: 'dark',
  setThemeMode: () => {},
})

export function PlatformProvider({ children }: { children: React.ReactNode }) {
  const [platform, setPlatformState] = useState<Platform>(() =>
    (localStorage.getItem('ask-platform') as Platform) ?? 'ios'
  )
  const [themeMode, setThemeModeState] = useState<ThemeMode>(() =>
    (localStorage.getItem('ask-theme') as ThemeMode) ?? 'dark'
  )

  function setPlatform(p: Platform) {
    setPlatformState(p)
    localStorage.setItem('ask-platform', p)
  }
  function setThemeMode(t: ThemeMode) {
    setThemeModeState(t)
    localStorage.setItem('ask-theme', t)
  }

  return (
    <Ctx.Provider value={{ platform, setPlatform, themeMode, setThemeMode }}>
      {children}
    </Ctx.Provider>
  )
}

export function usePlatform() { return useContext(Ctx) }

// ---------------------------------------------------------------------------
// PlatformIcon — SF Symbol approximations on iOS, Material Symbols on Android
// ---------------------------------------------------------------------------
// Android icons use the Material Symbols Rounded variable font.
// The `fill` prop renders filled variant (for active states).

interface IconProps {
  ios: string      // Unicode / emoji approximating an SF Symbol
  android: string  // Material Symbol ligature name (e.g. "home", "arrow_back")
  fill?: boolean   // Android only: use filled variant (active state)
  size?: number    // px, default 20
  className?: string
}

export function PlatformIcon({ ios, android, fill = false, size = 20, className = '' }: IconProps) {
  const { platform } = usePlatform()
  if (platform === 'android') {
    return (
      <span
        className={`mat-icon select-none ${className}`}
        style={{
          fontSize: size,
          fontVariationSettings: `'FILL' ${fill ? 1 : 0}, 'wght' 400, 'GRAD' 0, 'opsz' ${size}`,
        }}
      >
        {android}
      </span>
    )
  }
  // iOS: plain unicode character, sized and styled by caller via className
  return <span className={`select-none leading-none ${className}`} style={{ fontSize: size }}>{ios}</span>
}

// ---------------------------------------------------------------------------
// useTheme — platform-specific design tokens as Tailwind class strings
//
// iOS follows Apple HIG: SF Pro typography, 44pt touch targets,
//   inset-grouped rounded containers, system blue tinted buttons.
// Android follows Material Design 3: Roboto, 56dp touch targets,
//   pill buttons, outlined/filled-tonal variants, M3 elevation.
// ---------------------------------------------------------------------------

export function useTheme() {
  const { platform } = usePlatform()
  const md = platform === 'android'

  if (md) {
    return {
      platform,
      isAndroid: true,

      // M3 Typography (Roboto)
      typeTitleLarge:   'text-[22px] font-medium leading-7',
      typeTitleMedium:  'text-base font-medium leading-6 tracking-[0.15px]',
      typeBodyLarge:    'text-base font-normal leading-6 tracking-[0.5px]',
      typeBodyMedium:   'text-sm font-normal leading-5 tracking-[0.25px]',
      typeLabelLarge:   'text-sm font-medium leading-5 tracking-[0.1px]',
      typeLabelMedium:  'text-xs font-medium leading-4 tracking-[0.5px]',
      typeBodySmall:    'text-xs font-normal leading-4 tracking-[0.4px]',

      // Section header — sentence case, bodySmall/labelMedium
      sectionHeader: 'text-xs font-medium tracking-[0.4px] text-ask-secondary',

      // M3 Cards — no border, elevation shadow
      card: 'bg-ask-card rounded-2xl shadow-md shadow-black/40',

      // M3 Buttons — pill shaped (fully rounded)
      btnFilled:     'rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] bg-ask-blue text-white active:opacity-90 transition-opacity',
      btnTonal:      'rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] bg-ask-blue/20 text-ask-blue active:bg-ask-blue/30 transition-colors',
      btnOutlined:   'rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] border border-ask-sep text-ask-secondary hover:bg-ask-card2 active:bg-ask-card2 transition-colors',
      btnText:       'rounded-full min-h-[40px] px-4 text-sm font-medium tracking-[0.1px] text-ask-blue hover:bg-ask-blue/10 transition-colors',

      // Semantic variants
      btnAllow:      'rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] bg-ask-green/20 text-ask-green active:bg-ask-green/30 transition-colors',
      btnDeny:       'rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] bg-ask-red/20 text-ask-red active:bg-ask-red/30 transition-colors',

      // Option list — separate tonal buttons stacked
      optionContainer: 'flex flex-col gap-2',
      optionBtn: (i: number, total: number) => { void i; void total; return '' },
      optionBtnPrimary: 'w-full rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] bg-ask-blue/20 text-ask-blue active:bg-ask-blue/30 transition-colors',
      optionBtnSecondary: 'w-full rounded-full min-h-[40px] px-6 text-sm font-medium tracking-[0.1px] border border-ask-sep text-ask-secondary hover:bg-ask-card2 active:bg-ask-card2 transition-colors',

      // M3 Input — OutlinedTextField
      input: 'w-full rounded-xl border border-ask-sep bg-transparent px-4 py-3 text-base font-normal tracking-[0.5px] text-ask-text placeholder-ask-secondary focus:border-ask-blue outline-none transition-colors',

      // List item — M3 ListTile: 56dp min height, 16dp padding
      listItem: 'flex items-center gap-4 px-4 min-h-[56px]',
      listDivider: 'h-px bg-ask-sep/40',

      // Nav back
      navBackClass: 'flex items-center gap-1 text-ask-text',
      navBackIcon: <PlatformIcon ios="‹" android="arrow_back" size={22} />,
    }
  }

  // iOS HIG
  return {
    platform,
    isAndroid: false,

    // SF Pro typography (pt → px approximate)
    typeTitleLarge:   'text-[17px] font-semibold leading-snug',  // headline
    typeTitleMedium:  'text-[17px] font-semibold leading-snug',  // headline
    typeBodyLarge:    'text-[17px] font-normal leading-snug',    // body
    typeBodyMedium:   'text-[15px] font-normal leading-normal',  // subheadline
    typeLabelLarge:   'text-[13px] font-normal',                 // footnote
    typeLabelMedium:  'text-[11px] font-normal',                 // caption2
    typeBodySmall:    'text-[11px] font-normal',                 // caption2

    // Section header — ALL CAPS, footnote, secondary
    sectionHeader: 'text-[13px] font-semibold uppercase tracking-wider text-ask-secondary',

    // iOS card — subtle border (0.5pt equivalent), 8pt corner
    card: 'bg-ask-card rounded-xl border border-ask-sep/30',

    // iOS buttons — rounded-lg (6pt corner), system tint fills
    btnFilled:     'rounded-lg min-h-[32px] px-4 py-1.5 text-[15px] font-semibold bg-ask-blue text-white active:opacity-70 transition-opacity',
    btnTonal:      'rounded-lg min-h-[32px] px-4 py-1.5 text-[15px] font-semibold bg-ask-blue/[0.12] text-ask-blue active:bg-ask-blue/25 transition-colors',
    btnOutlined:   'rounded-lg min-h-[32px] px-4 py-1.5 text-[15px] font-semibold bg-ask-card2 text-ask-text active:opacity-70 transition-opacity',
    btnText:       'px-3 py-1.5 text-[17px] font-normal text-ask-blue active:opacity-60',

    // Semantic
    btnAllow:      'rounded-lg min-h-[32px] px-4 py-1.5 text-[15px] font-semibold bg-ask-green/[0.12] text-ask-green active:bg-ask-green/25 transition-colors',
    btnDeny:       'rounded-lg min-h-[32px] px-4 py-1.5 text-[15px] font-semibold bg-ask-orange/[0.12] text-ask-orange active:bg-ask-orange/25 transition-colors',

    // Option list — iOS inset-grouped table view style
    optionContainer: 'rounded-xl overflow-hidden border border-ask-sep/30 bg-ask-card',
    optionBtn: (_i: number, _total: number) => '',
    optionBtnPrimary: 'w-full min-h-[44px] px-4 flex items-center text-[15px] font-normal text-ask-blue active:bg-ask-card2 transition-colors border-b border-ask-sep/30 last:border-b-0',
    optionBtnSecondary: 'w-full min-h-[44px] px-4 flex items-center text-[15px] font-normal text-ask-blue active:bg-ask-card2 transition-colors border-b border-ask-sep/30 last:border-b-0',

    // iOS input — UITextField .roundedBorder: gray bg, subtle border, 15pt
    input: 'w-full rounded-lg border border-ask-sep/50 bg-ask-card2 px-3 py-2 text-[15px] font-normal text-ask-text placeholder-ask-secondary focus:border-ask-blue/60 outline-none transition-colors',

    // List item — UITableViewCell: 44pt min height, 10pt+ padding
    listItem: 'flex items-center gap-3 px-3 min-h-[44px]',
    listDivider: 'h-px bg-ask-sep/40 ml-3',

    // Nav back — blue chevron + label (iOS NavigationBar back button)
    navBackClass: 'flex items-center gap-0.5 text-ask-blue text-[17px] font-normal',
    navBackIcon: <CaretLeft size={20} weight="regular" />,
  }
}
