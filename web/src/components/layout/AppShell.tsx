import { useLocation, useNavigate } from 'react-router-dom'
import { useState, useEffect, useRef, createContext, useContext } from 'react'
import { Newspaper, GearSix, Bell } from '@phosphor-icons/react'
import type { Icon } from '@phosphor-icons/react'
import { usePlatform, type Platform, type ThemeMode } from '../../lib/PlatformContext'
import { ThemeProvider } from '@mui/material/styles'
import CssBaseline from '@mui/material/CssBaseline'
import { useMuiTheme } from '../../lib/muiTheme'
import { useStartSession } from '../../lib/StartSessionContext'
import { useBlocks } from '../../lib/useBlocks'
import Dialog from '@mui/material/Dialog'
import DialogTitle from '@mui/material/DialogTitle'
import List from '@mui/material/List'
import ListItemButton from '@mui/material/ListItemButton'
import ListItemIcon from '@mui/material/ListItemIcon'
import ListItemText from '@mui/material/ListItemText'

// ---- Brand color context — screens set this so AppShell can tint the iOS status bar ----

interface BrandColorCtx { brandColor: string | null; setBrandColor: (c: string | null) => void }
const BrandColorContext = createContext<BrandColorCtx>({ brandColor: null, setBrandColor: () => {} })
export function useBrandColor() { return useContext(BrandColorContext) }

// Natural phone dimensions (screen + frame padding + side buttons)
const PHONE_W = 420  // 390 screen + 11*2 frame + 4*2 buttons (approx)
const PHONE_H = 866  // 844 screen + 11*2 frame
const MIN_SCALE = 0.35

function usePhoneScale(containerRef: React.RefObject<HTMLDivElement | null>) {
  const [scale, setScale] = useState(1)

  useEffect(() => {
    function update() {
      const el = containerRef.current
      if (!el) return
      const availW = el.clientWidth
      const availH = el.clientHeight
      const s = Math.max(MIN_SCALE, Math.min(1, availW / PHONE_W, availH / PHONE_H))
      setScale(s)
    }
    update()
    const ro = new ResizeObserver(update)
    if (containerRef.current) ro.observe(containerRef.current)
    return () => ro.disconnect()
  }, [containerRef])

  return scale
}

interface Props { children: React.ReactNode }

// Tab definitions — iOS uses Home/Feed inline switcher + gear for settings
const IOS_TABS: Array<{ key: string; label: string; path: string }> = [
  { key: 'home',  label: 'Home', path: '/home'  },
  { key: 'tasks', label: 'Feed', path: '/tasks' },
]

const ANDROID_TABS: Array<{ key: string; label: string; path: string; iosIcon: Icon; android: string }> = [
  { key: 'home',     label: 'Home',     path: '/home',     iosIcon: Newspaper, android: 'home' },
  { key: 'tasks',    label: 'Feed',     path: '/tasks',    iosIcon: Newspaper, android: 'dynamic_feed' },
  { key: 'settings', label: 'Settings', path: '/settings', iosIcon: GearSix,   android: 'settings' },
]

// ---- Control bar (above the phone) ----

function SegControl<T extends string>({
  options,
  value,
  onChange,
}: {
  options: Array<{ value: T; label: string }>
  value: T
  onChange: (v: T) => void
}) {
  return (
    <div className="flex rounded-lg p-0.5" style={{ background: 'rgba(0,0,0,0.08)' }}>
      {options.map(opt => (
        <button
          key={opt.value}
          onClick={() => onChange(opt.value)}
          className={`px-3 py-1 rounded-md text-[12px] font-semibold transition-all ${
            value === opt.value
              ? 'bg-white text-gray-800 shadow-sm'
              : 'text-gray-500 hover:text-gray-700'
          }`}
        >
          {opt.label}
        </button>
      ))}
    </div>
  )
}

function ControlBar() {
  const { platform, setPlatform, themeMode, setThemeMode } = usePlatform()
  return (
    <div
      className="sticky top-0 z-10 flex items-center justify-center gap-3 px-6 py-2.5 border-b"
      style={{
        background: 'rgba(245,245,247,0.85)',
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
        borderColor: 'rgba(0,0,0,0.1)',
      }}
    >
      <SegControl<Platform>
        options={[{ value: 'ios', label: 'iOS' }, { value: 'android', label: 'Android' }]}
        value={platform}
        onChange={setPlatform}
      />
      <SegControl<ThemeMode>
        options={[{ value: 'dark', label: 'Dark' }, { value: 'light', label: 'Light' }]}
        value={themeMode}
        onChange={setThemeMode}
      />
    </div>
  )
}

// ---- Phone frame side buttons ----

// iPhone 16 Pro: Action button + Vol+/- on left, Power on right
function IOSPhoneButtons({ isLight }: { isLight: boolean }) {
  const color = isLight
    ? 'linear-gradient(90deg, #b0b0b0 0%, #d0d0d0 40%, #c0c0c0 100%)'
    : 'linear-gradient(90deg, #5a5a5e 0%, #8e8e93 40%, #6e6e73 100%)'
  const shadow = isLight
    ? '-1px 0 3px rgba(0,0,0,0.15)'
    : '-1px 0 3px rgba(0,0,0,0.4)'
  const shadowR = isLight
    ? '1px 0 3px rgba(0,0,0,0.15)'
    : '1px 0 3px rgba(0,0,0,0.4)'

  const left = (top: number, height: number) => (
    <div style={{
      position: 'absolute', left: -4, top, width: 4, height,
      background: color, borderRadius: '2px 0 0 2px', boxShadow: shadow,
    }} />
  )
  const right = (top: number, height: number) => (
    <div style={{
      position: 'absolute', right: -4, top, width: 4, height,
      background: color.replace('90deg', '270deg'), borderRadius: '0 2px 2px 0', boxShadow: shadowR,
    }} />
  )

  return (
    <>
      {left(98, 32)}   {/* Action button */}
      {left(162, 68)}  {/* Vol+ */}
      {left(242, 68)}  {/* Vol- */}
      {right(170, 90)} {/* Power */}
    </>
  )
}

// Pixel 9 Pro: Power + Vol+/- all on right
function AndroidPhoneButtons({ isLight }: { isLight: boolean }) {
  const color = isLight
    ? 'linear-gradient(270deg, #a0a0a0 0%, #c8c8c8 40%, #b0b0b0 100%)'
    : 'linear-gradient(270deg, #2a2a2a 0%, #4a4a4a 40%, #3a3a3a 100%)'

  const right = (top: number, height: number) => (
    <div style={{
      position: 'absolute', right: -4, top, width: 4, height,
      background: color, borderRadius: '0 2px 2px 0',
      boxShadow: isLight ? '1px 0 3px rgba(0,0,0,0.15)' : '1px 0 3px rgba(0,0,0,0.5)',
    }} />
  )

  return (
    <>
      {right(185, 55)} {/* Power */}
      {right(253, 55)} {/* Vol+ */}
      {right(320, 55)} {/* Vol- */}
    </>
  )
}

// ---- iOS status bar — Dynamic Island + time + signal ----

function IOSStatusBar({ isLight }: { isLight: boolean }) {
  const time = new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
  return (
    <div
      className="flex-shrink-0 relative flex items-center justify-between px-6 h-12"
      style={{
        backdropFilter: 'blur(20px)',
        WebkitBackdropFilter: 'blur(20px)',
        background: isLight ? 'rgba(242,242,247,0.72)' : 'rgba(28,28,30,0.72)',
      }}
    >
      <span className="text-[15px] font-semibold text-ask-text tabular-nums">{time}</span>
      {/* Dynamic Island */}
      <div className="absolute left-1/2 top-2 -translate-x-1/2 w-[120px] h-[34px] bg-black rounded-full" />
      {/* Signal / battery icons */}
      <div className="flex items-center gap-[5px] text-ask-text">
        <span className="text-[10px] font-bold tracking-[-2px]">●●●</span>
        <span className="mat-icon" style={{ fontSize: 16, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 16" }}>wifi</span>
        <span className="mat-icon" style={{ fontSize: 16, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 16" }}>battery_full</span>
      </div>
    </div>
  )
}

// ---- Android status bar — punch-hole camera + M3 status icons ----

function AndroidStatusBar() {
  const time = new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false })
  return (
    <div className="flex-shrink-0 relative flex items-center justify-between px-5 h-[28px]">
      <span className="text-[12px] font-medium tabular-nums text-ask-secondary">{time}</span>
      {/* Punch-hole camera */}
      <div className="absolute left-1/2 top-[6px] -translate-x-1/2 w-[11px] h-[11px] bg-black rounded-full" />
      {/* M3 status icons */}
      <div className="flex items-center gap-1 text-ask-secondary">
        <span className="mat-icon" style={{ fontSize: 14, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 14" }}>signal_cellular_alt</span>
        <span className="mat-icon" style={{ fontSize: 14, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 14" }}>wifi</span>
        <span className="mat-icon" style={{ fontSize: 14, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 14" }}>battery_full</span>
      </div>
    </div>
  )
}

// ---- iOS bottom bar — floating pill matching the real iOS app ----

function IOSTabBar({ tab, isLight }: { tab: string; isLight: boolean }) {
  const navigate = useNavigate()
  const { action } = useStartSession()
  const { blocks } = useBlocks()
  const [popoverOpen, setPopoverOpen] = useState(false)
  const [bellOpen, setBellOpen] = useState(false)

  // Compute alert groups: blocks with showsInInbox === 1, grouped by scriptID
  const alertGroups = blocks
    .filter(b => b.showsInInbox === 1)
    .reduce<Record<string, { scriptName: string; count: number }>>((acc, b) => {
      if (!acc[b.scriptID]) acc[b.scriptID] = { scriptName: b.scriptName, count: 0 }
      acc[b.scriptID].count++
      return acc
    }, {})
  const hasAlerts = Object.keys(alertGroups).length > 0

  const pillBg = isLight ? 'rgba(255,255,255,0.95)' : 'rgba(28,28,30,0.95)'
  const pillBorder = isLight ? '1px solid rgba(0,0,0,0.10)' : '1px solid rgba(255,255,255,0.10)'
  const pillShadow = isLight
    ? '0 6px 24px rgba(0,0,0,0.12), 0 2px 8px rgba(0,0,0,0.06)'
    : '0 6px 24px rgba(0,0,0,0.5), 0 2px 8px rgba(0,0,0,0.3)'
  const iconColor = isLight ? 'rgba(0,0,0,0.85)' : 'rgba(255,255,255,0.85)'

  return (
    <div className="flex flex-col items-center pt-1 pb-4 relative">
      {/* Bell popover — alert sources */}
      {bellOpen && hasAlerts && (
        <div
          className="absolute bottom-full mb-2 rounded-2xl overflow-hidden"
          style={{
            background: pillBg,
            backdropFilter: 'blur(20px)',
            WebkitBackdropFilter: 'blur(20px)',
            border: pillBorder,
            boxShadow: pillShadow,
            minWidth: 200,
          }}
        >
          <p className="text-[13px] font-semibold px-4 pt-3 pb-1.5" style={{ color: iconColor }}>
            Alerts
          </p>
          {Object.entries(alertGroups).map(([scriptID, { scriptName, count }], i, arr) => (
            <button
              key={scriptID}
              onClick={() => { navigate(`/script/${scriptID}`); setBellOpen(false) }}
              className={`w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-white/10 transition-colors ${
                i < arr.length - 1 ? 'border-b' : ''
              }`}
              style={{ borderColor: isLight ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.08)' }}
            >
              <span className="text-base leading-none">🔔</span>
              <div className="flex-1 min-w-0">
                <p className="text-[14px] font-medium truncate" style={{ color: iconColor }}>{scriptName}</p>
              </div>
              {count > 1 && (
                <span className="text-[11px] font-bold px-1.5 py-0.5 rounded-full bg-ask-red/20 text-ask-red">{count}</span>
              )}
            </button>
          ))}
        </div>
      )}

      {/* Repo popover — floats above the pill, no full-screen overlay */}
      {popoverOpen && action && (
        <div
          className="absolute bottom-full mb-2 rounded-2xl overflow-hidden"
          style={{
            background: pillBg,
            backdropFilter: 'blur(20px)',
            WebkitBackdropFilter: 'blur(20px)',
            border: pillBorder,
            boxShadow: pillShadow,
            minWidth: 220,
          }}
        >
          <p className="text-[13px] font-semibold px-4 pt-3 pb-1.5" style={{ color: iconColor }}>
            Choose a repository
          </p>
          {action.payload.repos.map((repo, i) => (
            <button
              key={repo.path}
              onClick={() => { action.respond(action.block.blockID, repo.path); setPopoverOpen(false) }}
              className={`w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-white/10 transition-colors ${
                i < action.payload.repos.length - 1 ? 'border-b' : ''
              }`}
              style={{ borderColor: isLight ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.08)' }}
            >
              <span className="text-base leading-none">📁</span>
              <div className="min-w-0">
                <p className="text-[14px] font-medium truncate" style={{ color: iconColor }}>{repo.name}</p>
                <p className="text-[10px] font-mono truncate" style={{ color: isLight ? 'rgba(0,0,0,0.4)' : 'rgba(255,255,255,0.4)' }}>{repo.path}</p>
              </div>
            </button>
          ))}
        </div>
      )}

      {/* Tap outside to dismiss */}
      {(popoverOpen || bellOpen) && (
        <div className="absolute inset-0 z-[-1]" onClick={() => { setPopoverOpen(false); setBellOpen(false) }} />
      )}

      {/* Floating pill */}
      <div
        className="flex items-center px-[18px] py-[10px] gap-3"
        style={{ background: pillBg, backdropFilter: 'blur(20px)', WebkitBackdropFilter: 'blur(20px)', borderRadius: 28, border: pillBorder, boxShadow: pillShadow }}
      >
        {/* Left: bell icon (only when alerts exist) */}
        {hasAlerts && (
          <button
            onClick={() => { setBellOpen(v => !v); setPopoverOpen(false) }}
            className="flex items-center justify-center transition-opacity hover:opacity-70 relative"
            style={{ color: '#ff453a', width: 24, height: 24 }}
          >
            <Bell
              size={18}
              weight="fill"
              style={{ animation: 'bell-rock 2.5s ease-in-out infinite' }}
            />
          </button>
        )}

        {/* "+" to start session (only when available) */}
        {action && (
          <button
            onClick={() => { setPopoverOpen(v => !v); setBellOpen(false) }}
            className="flex items-center justify-center transition-opacity hover:opacity-70"
            style={{ color: iconColor, fontSize: 22, fontWeight: 300, lineHeight: 1, width: 24, height: 24 }}
          >
            +
          </button>
        )}

        {/* Home / Feed tab switcher */}
        <div className="flex items-center gap-0.5">
          {IOS_TABS.map(item => {
            const active = tab === item.key
            return (
              <button
                key={item.key}
                onClick={() => navigate(item.path)}
                className="flex items-center px-3 py-[5px] rounded-full transition-all"
                style={{
                  background: active ? (isLight ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.12)') : 'transparent',
                  color: active ? (isLight ? 'rgba(0,0,0,0.9)' : 'rgba(255,255,255,0.9)') : (isLight ? 'rgba(0,0,0,0.45)' : 'rgba(255,255,255,0.45)'),
                  fontSize: 15,
                  fontWeight: active ? 600 : 400,
                  lineHeight: 1,
                }}
              >
                {item.label}
              </button>
            )
          })}
        </div>

        {/* Right: settings gear */}
        <button
          onClick={() => navigate('/settings')}
          className="flex items-center justify-center"
          style={{ color: iconColor }}
        >
          <GearSix size={20} weight="regular" />
        </button>
      </div>

    </div>
  )
}

// ---- Android M3 Navigation Bar ----

function AndroidTabBar({ tab }: { tab: string }) {
  const navigate = useNavigate()
  const { action } = useStartSession()
  const { blocks } = useBlocks()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [bellDialogOpen, setBellDialogOpen] = useState(false)

  const alertGroups = blocks
    .filter(b => b.showsInInbox === 1)
    .reduce<Record<string, { scriptName: string; count: number }>>((acc, b) => {
      if (!acc[b.scriptID]) acc[b.scriptID] = { scriptName: b.scriptName, count: 0 }
      acc[b.scriptID].count++
      return acc
    }, {})
  const hasAlerts = Object.keys(alertGroups).length > 0

  return (
    <div className="flex-shrink-0 bg-ask-card" style={{ boxShadow: '0 -1px 0 rgb(73 69 79 / 0.4)' }}>
      <div className="flex items-stretch">
        {ANDROID_TABS.map(item => {
          const active = tab === item.key
          return (
            <button
              key={item.key}
              onClick={() => navigate(item.path)}
              className="flex-1 flex flex-col items-center justify-center gap-1 pt-3 pb-2"
            >
              <div className={`flex items-center justify-center w-16 h-8 rounded-full transition-colors ${active ? 'bg-ask-blue/20' : ''}`}>
                <span
                  className={`mat-icon select-none ${active ? 'text-ask-blue' : 'text-ask-secondary'}`}
                  style={{ fontSize: 24, fontVariationSettings: `'FILL' ${active ? 1 : 0}, 'wght' 400, 'GRAD' 0, 'opsz' 24` }}
                >
                  {item.android}
                </span>
              </div>
              <span className={`text-[12px] font-medium tracking-[0.5px] transition-colors ${active ? 'text-ask-blue' : 'text-ask-secondary'}`}>
                {item.label}
              </span>
            </button>
          )
        })}

        {/* Bell tab — only visible when there are alert blocks */}
        {hasAlerts && (
          <button
            onClick={() => setBellDialogOpen(true)}
            className="flex-1 flex flex-col items-center justify-center gap-1 pt-3 pb-2"
          >
            <div className="flex items-center justify-center w-16 h-8 rounded-full">
              <Bell
                size={22}
                weight="fill"
                color="#ff453a"
                style={{ animation: 'bell-rock 2.5s ease-in-out infinite' }}
              />
            </div>
            <span className="text-[12px] font-medium tracking-[0.5px] text-ask-red">Alerts</span>
          </button>
        )}

        {/* "+" button — only visible when a start_session block is available */}
        {action && (
          <button
            onClick={() => setDialogOpen(true)}
            className="flex-1 flex flex-col items-center justify-center gap-1 pt-3 pb-2"
          >
            <div className="flex items-center justify-center w-16 h-8 rounded-full">
              <span className="mat-icon select-none text-ask-secondary" style={{ fontSize: 24 }}>add</span>
            </div>
            <span className="text-[12px] font-medium tracking-[0.5px] text-ask-secondary">New</span>
          </button>
        )}
      </div>

      {/* Android gesture navigation bar */}
      <div className="flex justify-center py-2">
        <div className="w-[134px] h-[5px] rounded-full bg-ask-secondary/20" />
      </div>

      {/* MUI Dialog for alerts */}
      <Dialog open={bellDialogOpen} onClose={() => setBellDialogOpen(false)} fullWidth maxWidth="xs">
        <DialogTitle>Alerts</DialogTitle>
        <List sx={{ pt: 0 }}>
          {Object.entries(alertGroups).map(([scriptID, { scriptName, count }]) => (
            <ListItemButton key={scriptID} onClick={() => { navigate(`/script/${scriptID}`); setBellDialogOpen(false) }}>
              <ListItemIcon>
                <span className="mat-icon" style={{ fontSize: 24, color: '#ff453a', fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 24" }}>notifications</span>
              </ListItemIcon>
              <ListItemText primary={scriptName} secondary={count > 1 ? `${count} alerts` : '1 alert'} />
            </ListItemButton>
          ))}
        </List>
      </Dialog>

      {/* MUI Dialog for repo selection */}
      {action && (
        <Dialog open={dialogOpen} onClose={() => setDialogOpen(false)} fullWidth maxWidth="xs">
          <DialogTitle>Choose a repository</DialogTitle>
          <List sx={{ pt: 0 }}>
            {action.payload.repos.map(repo => (
              <ListItemButton key={repo.path} onClick={() => { action.respond(action.block.blockID, repo.path); setDialogOpen(false) }}>
                <ListItemIcon>
                  <span className="mat-icon" style={{ fontSize: 24, fontVariationSettings: "'FILL' 0, 'wght' 400, 'opsz' 24" }}>folder</span>
                </ListItemIcon>
                <ListItemText primary={repo.name} secondary={repo.path} slotProps={{ secondary: { sx: { fontFamily: 'monospace', fontSize: 10 } } }} />
              </ListItemButton>
            ))}
          </List>
        </Dialog>
      )}
    </div>
  )
}

// ---- Shell ----

export default function AppShell({ children }: Props) {
  const location = useLocation()
  const { platform, themeMode } = usePlatform()
  const isAndroid = platform === 'android'
  const isLight = themeMode === 'light'
  const muiTheme = useMuiTheme()
  const [brandColor, setBrandColor] = useState<string | null>(null)

  const phoneAreaRef = useRef<HTMLDivElement>(null)
  const scale = usePhoneScale(phoneAreaRef)

  const tab = location.pathname.startsWith('/tasks') ? 'tasks'
    : location.pathname.startsWith('/settings') ? 'settings'
    : 'home'

  // iPhone 16 Pro: 390px wide, titanium frame
  // Pixel 9 Pro: slightly different corner radius, dark metal frame
  const outerRadius = isAndroid ? 46 : 52
  const innerRadius = isAndroid ? 36 : 42
  const framePad = isAndroid ? 9 : 11

  const frameBackground = isAndroid
    ? (isLight
        ? 'linear-gradient(135deg, #b8b8ba 0%, #888 30%, #a0a0a2 70%, #c0c0c2 100%)'
        : 'linear-gradient(135deg, #3a3a3c 0%, #1c1c1e 30%, #2c2c2e 70%, #3a3a3c 100%)')
    : (isLight
        ? 'linear-gradient(145deg, #d0d0d4 0%, #a8a8ad 25%, #8e8e93 50%, #b0b0b5 75%, #d0d0d4 100%)'
        : 'linear-gradient(145deg, #9a9a9f 0%, #6e6e73 25%, #5a5a5e 50%, #7a7a7f 75%, #9a9a9f 100%)')

  const frameBoxShadow = isLight
    ? '0 0 0 0.5px rgba(0,0,0,0.12), 0 8px 32px rgba(0,0,0,0.12), 0 2px 8px rgba(0,0,0,0.08)'
    : '0 0 0 0.5px rgba(0,0,0,0.3), 0 20px 60px rgba(0,0,0,0.4), 0 4px 16px rgba(0,0,0,0.3)'

  return (
    <div className="min-h-screen flex flex-col" style={{ background: '#f5f5f7' }}>
      <ControlBar />

      {/* Phone area */}
      <div ref={phoneAreaRef} className="flex-1 flex items-start justify-center py-8 px-8 overflow-hidden">
        {/* zoom affects layout (unlike transform:scale), so sizing and absolute buttons all work naturally */}
        <div className="relative flex-shrink-0" style={{ zoom: scale }}>
          {/* Side buttons */}
          {isAndroid
            ? <AndroidPhoneButtons isLight={isLight} />
            : <IOSPhoneButtons isLight={isLight} />
          }

          {/* Phone frame (metallic border) */}
          <div style={{
            background: frameBackground,
            borderRadius: outerRadius,
            padding: framePad,
            boxShadow: frameBoxShadow,
          }}>
            {/* Screen content */}
            <div
              className={`flex flex-col ${isAndroid ? 'platform-android' : ''} ${isLight ? 'theme-light' : ''}`}
              style={{
                position: 'relative',
                width: 390,
                height: 844,
                borderRadius: innerRadius,
                overflow: 'hidden',
                background: !isAndroid && brandColor
                  ? `linear-gradient(180deg, ${brandColor}22 0%, ${isLight ? 'rgb(242,242,247)' : 'rgb(28,28,30)'} 110px)`
                  : (isAndroid
                      ? (isLight ? 'rgb(255 251 254)' : 'rgb(20 18 24)')
                      : (isLight ? 'rgb(242 242 247)' : 'rgb(28 28 30)')),
              }}
            >
              {isAndroid ? <AndroidStatusBar /> : <IOSStatusBar isLight={isLight} />}

              <BrandColorContext.Provider value={{ brandColor, setBrandColor }}>
                <div className="flex-1 overflow-y-auto no-scrollbar min-h-0">
                  {isAndroid ? (
                    <ThemeProvider theme={muiTheme}>
                      <CssBaseline enableColorScheme={false} />
                      {children}
                    </ThemeProvider>
                  ) : children}
                </div>
              </BrandColorContext.Provider>

              {isAndroid
                ? <AndroidTabBar tab={tab} />
                : <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0 }}><IOSTabBar tab={tab} isLight={isLight} /></div>
              }
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
