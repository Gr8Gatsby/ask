import { useLocation, useNavigate } from 'react-router-dom'
import { usePlatform, type Platform } from '../../lib/PlatformContext'

interface Props { children: React.ReactNode }

const TABS = [
  { key: 'home',    label: 'Home',    path: '/home',    iosIcon: '⊞', androidIcon: '⊞' },
  { key: 'tasks',   label: 'Feed',    path: '/tasks',   iosIcon: '◈', androidIcon: '◈' },
  { key: 'catalog', label: 'Catalog', path: '/catalog', iosIcon: '⊟', androidIcon: '⊟' },
]

// ---- Platform switcher (lives in outer black frame) ----

function PlatformSwitcher() {
  const { platform, setPlatform } = usePlatform()

  const btn = (p: Platform, label: string) => (
    <button
      key={p}
      onClick={() => setPlatform(p)}
      className={`px-2.5 py-1 rounded text-[11px] font-semibold transition-colors ${
        platform === p
          ? 'bg-white/20 text-white'
          : 'text-white/35 hover:text-white/65'
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

// ---- iOS tab bar ----

function IOSTabBar({ tab }: { tab: string }) {
  const navigate = useNavigate()
  return (
    <div className="flex-shrink-0 border-t border-ask-sep bg-ask-bg/95 backdrop-blur-sm">
      <div className="flex items-center">
        {TABS.map(item => (
          <button
            key={item.key}
            onClick={() => navigate(item.path)}
            className={`flex-1 flex flex-col items-center gap-0.5 py-2 text-[10px] transition-colors ${
              tab === item.key ? 'text-ask-blue' : 'text-ask-secondary'
            }`}
          >
            <span className="text-lg leading-none">{item.iosIcon}</span>
            <span>{item.label}</span>
          </button>
        ))}
      </div>
      {/* Home indicator */}
      <div className="flex justify-center pb-1.5">
        <div className="w-28 h-[5px] rounded-full bg-white/20" />
      </div>
    </div>
  )
}

// ---- Android M3 navigation bar ----

function AndroidTabBar({ tab }: { tab: string }) {
  const navigate = useNavigate()
  return (
    <div className="flex-shrink-0 bg-ask-card shadow-lg shadow-black/60">
      <div className="flex items-center">
        {TABS.map(item => {
          const active = tab === item.key
          return (
            <button
              key={item.key}
              onClick={() => navigate(item.path)}
              className="flex-1 flex flex-col items-center gap-0.5 py-2.5 transition-colors"
            >
              {/* M3 indicator pill — only on active */}
              <div className={`px-5 py-1 rounded-full transition-all ${
                active ? 'bg-ask-blue/20' : ''
              }`}>
                <span className={`text-base leading-none transition-colors ${
                  active ? 'text-ask-blue' : 'text-ask-secondary'
                }`}>
                  {item.androidIcon}
                </span>
              </div>
              <span className={`text-[10px] font-medium transition-colors ${
                active ? 'text-ask-blue' : 'text-ask-secondary'
              }`}>
                {item.label}
              </span>
            </button>
          )
        })}
      </div>
      {/* Android gesture bar */}
      <div className="flex justify-center pb-2 pt-0.5">
        <div className="w-16 h-1 rounded-full bg-ask-secondary/25" />
      </div>
    </div>
  )
}

// ---- Shell ----

export default function AppShell({ children }: Props) {
  const location = useLocation()
  const { platform } = usePlatform()

  const tab = location.pathname.startsWith('/tasks') ? 'tasks'
    : location.pathname.startsWith('/catalog') ? 'catalog'
    : 'home'

  const isAndroid = platform === 'android'

  return (
    // Outer frame — always black. PlatformSwitcher is anchored here.
    <div className="h-full flex justify-center bg-black relative">
      <PlatformSwitcher />

      {/* Phone shell — platform class scopes CSS variable overrides */}
      <div className={`w-full max-w-[390px] flex flex-col h-full relative overflow-hidden ${
        isAndroid ? 'platform-android' : ''
      }`}
        style={{ backgroundColor: isAndroid ? 'rgb(20 18 24)' : 'rgb(28 28 30)' }}
      >
        {/* Status bar chrome */}
        {isAndroid ? (
          <AndroidStatusBar />
        ) : (
          <IOSStatusBar />
        )}

        {/* Screen content */}
        <div className="flex-1 overflow-y-auto no-scrollbar min-h-0">
          {children}
        </div>

        {/* Tab bar */}
        {isAndroid
          ? <AndroidTabBar tab={tab} />
          : <IOSTabBar tab={tab} />
        }
      </div>
    </div>
  )
}

// ---- Status bars ----

function IOSStatusBar() {
  const now = new Date()
  const time = now.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
  return (
    <div className="flex-shrink-0 flex items-center justify-between px-6 pt-3 pb-1 h-12">
      <span className="text-[13px] font-semibold text-white">{time}</span>
      {/* Dynamic island placeholder */}
      <div className="absolute left-1/2 top-2 -translate-x-1/2 w-24 h-7 bg-black rounded-full" />
      {/* Status icons */}
      <div className="flex items-center gap-1.5">
        <span className="text-[11px] text-white">●●●</span>
        <span className="text-[11px] text-white">WiFi</span>
        <span className="text-[11px] text-white">🔋</span>
      </div>
    </div>
  )
}

function AndroidStatusBar() {
  const now = new Date()
  const time = now.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: false })
  return (
    <div className="flex-shrink-0 flex items-center justify-between px-5 pt-2 pb-1 h-10">
      <span className="text-[12px] font-medium" style={{ color: 'rgb(230 225 229)' }}>{time}</span>
      {/* Punch-hole camera — centered */}
      <div className="absolute left-1/2 top-2 -translate-x-1/2 w-3 h-3 bg-black rounded-full" />
      {/* Status icons */}
      <div className="flex items-center gap-1.5">
        <span className="text-[11px]" style={{ color: 'rgb(202 196 208)' }}>▲ WiFi 🔋</span>
      </div>
    </div>
  )
}
