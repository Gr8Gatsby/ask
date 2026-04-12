import { useLocation, useNavigate } from 'react-router-dom'
import { usePlatform, PlatformIcon, type Platform } from '../../lib/PlatformContext'

interface Props { children: React.ReactNode }

// Tab definitions — ios: SF Symbol Unicode approx, android: Material Symbol name
const TABS = [
  { key: 'home',    label: 'Home',    path: '/home',    ios: '⌂',  android: 'home' },
  { key: 'tasks',   label: 'Feed',    path: '/tasks',   ios: '☰',  android: 'dynamic_feed' },
  { key: 'catalog', label: 'Catalog', path: '/catalog', ios: '▦',  android: 'apps' },
]

// ---- Platform switcher (outer black frame) ----

function PlatformSwitcher() {
  const { platform, setPlatform } = usePlatform()
  const btn = (p: Platform, label: string) => (
    <button
      key={p}
      onClick={() => setPlatform(p)}
      className={`px-2.5 py-1 rounded text-[11px] font-semibold transition-colors ${
        platform === p ? 'bg-white/20 text-white' : 'text-white/35 hover:text-white/65'
      }`}
    >
      {label}
    </button>
  )
  return (
    <div className="absolute top-3 right-3 z-50 flex gap-0.5 bg-white/8 backdrop-blur rounded-lg p-0.5">
      {btn('ios', 'iOS')}
      {btn('android', 'Android')}
    </div>
  )
}

// ---- iOS tab bar — UITabBar style ----
// Translucent blur background, thin top separator, icon + label, system blue active

function IOSTabBar({ tab }: { tab: string }) {
  const navigate = useNavigate()
  return (
    <div className="flex-shrink-0 border-t border-ask-sep/60 bg-ask-bg/90 backdrop-blur-md">
      <div className="flex items-stretch">
        {TABS.map(item => {
          const active = tab === item.key
          return (
            <button
              key={item.key}
              onClick={() => navigate(item.path)}
              className={`flex-1 flex flex-col items-center justify-center gap-[3px] pt-2 pb-1 min-h-[49px] transition-colors ${
                active ? 'text-ask-blue' : 'text-ask-secondary'
              }`}
            >
              {/* SF Symbol approximation — use PlatformIcon in ios mode */}
              <PlatformIcon
                ios={item.ios}
                android={item.android}
                fill={active}
                size={24}
                className={active ? 'text-ask-blue' : 'text-ask-secondary'}
              />
              <span className="text-[10px] font-normal leading-none">{item.label}</span>
            </button>
          )
        })}
      </div>
      {/* iOS home indicator */}
      <div className="flex justify-center pb-2">
        <div className="w-[134px] h-[5px] rounded-full bg-white/30" />
      </div>
    </div>
  )
}

// ---- Android M3 Navigation Bar ----
// Surface-container bg, no border, indicator pill behind active icon (filled variant)

function AndroidTabBar({ tab }: { tab: string }) {
  const navigate = useNavigate()
  return (
    <div className="flex-shrink-0 bg-ask-card" style={{ boxShadow: '0 -1px 0 rgb(73 69 79 / 0.4)' }}>
      <div className="flex items-stretch">
        {TABS.map(item => {
          const active = tab === item.key
          return (
            <button
              key={item.key}
              onClick={() => navigate(item.path)}
              className="flex-1 flex flex-col items-center justify-center gap-1 pt-3 pb-2"
            >
              {/* M3 nav indicator pill wraps icon, visible only on active */}
              <div className={`flex items-center justify-center w-16 h-8 rounded-full transition-colors ${
                active ? 'bg-ask-blue/20' : ''
              }`}>
                <PlatformIcon
                  ios={item.ios}
                  android={item.android}
                  fill={active}
                  size={24}
                  className={active ? 'text-ask-blue' : 'text-ask-secondary'}
                />
              </div>
              {/* M3 nav label: labelMedium 12sp/500 */}
              <span className={`text-[12px] font-medium tracking-[0.5px] transition-colors ${
                active ? 'text-ask-blue' : 'text-ask-secondary'
              }`}>
                {item.label}
              </span>
            </button>
          )
        })}
      </div>
      {/* Android gesture navigation bar */}
      <div className="flex justify-center py-2">
        <div className="w-[134px] h-[5px] rounded-full bg-ask-secondary/20" />
      </div>
    </div>
  )
}

// ---- iOS status bar — Dynamic Island + time + signal ----

function IOSStatusBar() {
  const time = new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
  return (
    <div className="flex-shrink-0 relative flex items-center justify-between px-6 h-12">
      <span className="text-[15px] font-semibold text-white tabular-nums">{time}</span>
      {/* Dynamic Island */}
      <div className="absolute left-1/2 top-2 -translate-x-1/2 w-[120px] h-[34px] bg-black rounded-full" />
      {/* Signal / battery icons (Unicode approximations of SF Symbols) */}
      <div className="flex items-center gap-[5px]">
        <span className="text-white text-[12px] font-semibold">●●●</span>
        <span className="mat-icon text-white" style={{ fontSize: 16, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 16" }}>wifi</span>
        <span className="mat-icon text-white" style={{ fontSize: 16, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 16" }}>battery_full</span>
      </div>
    </div>
  )
}

// ---- Android status bar — punch-hole camera + M3 status icons ----

function AndroidStatusBar() {
  const time = new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false })
  return (
    <div className="flex-shrink-0 relative flex items-center justify-between px-5 h-[28px]">
      <span className="text-[12px] font-medium tabular-nums" style={{ color: 'rgb(202 196 208)' }}>{time}</span>
      {/* Punch-hole camera */}
      <div className="absolute left-1/2 top-[6px] -translate-x-1/2 w-[11px] h-[11px] bg-black rounded-full" />
      {/* M3 status icons */}
      <div className="flex items-center gap-1">
        <span className="mat-icon" style={{ fontSize: 14, color: 'rgb(202 196 208)', fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 14" }}>signal_cellular_alt</span>
        <span className="mat-icon" style={{ fontSize: 14, color: 'rgb(202 196 208)', fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 14" }}>wifi</span>
        <span className="mat-icon" style={{ fontSize: 14, color: 'rgb(202 196 208)', fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 14" }}>battery_full</span>
      </div>
    </div>
  )
}

// ---- Shell ----

export default function AppShell({ children }: Props) {
  const location = useLocation()
  const { platform } = usePlatform()
  const isAndroid = platform === 'android'

  const tab = location.pathname.startsWith('/tasks') ? 'tasks'
    : location.pathname.startsWith('/catalog') ? 'catalog'
    : 'home'

  return (
    <div className="h-full flex justify-center bg-black relative">
      <PlatformSwitcher />

      <div
        className={`w-full max-w-[390px] flex flex-col h-full relative overflow-hidden ${
          isAndroid ? 'platform-android' : ''
        }`}
        style={{ backgroundColor: isAndroid ? 'rgb(20 18 24)' : 'rgb(28 28 30)' }}
      >
        {isAndroid ? <AndroidStatusBar /> : <IOSStatusBar />}

        <div className="flex-1 overflow-y-auto no-scrollbar min-h-0">
          {children}
        </div>

        {isAndroid ? <AndroidTabBar tab={tab} /> : <IOSTabBar tab={tab} />}
      </div>
    </div>
  )
}
