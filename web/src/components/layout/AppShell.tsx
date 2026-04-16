import { useLocation, useNavigate } from 'react-router-dom'
import { useState, useEffect, useRef, createContext, useContext } from 'react'
import { Newspaper, GearSix, Bell, Code, FrameCorners, FolderOpen } from '@phosphor-icons/react'
import type { Icon } from '@phosphor-icons/react'
import UIInspectorPanel from './UIInspectorPanel'
import RedlinesOverlay from './RedlinesOverlay'
import RedlinesDetailPanel from './RedlinesDetailPanel'
import { RedlinesProvider, useRedlines } from '../../lib/RedlinesContext'
import { usePlatform, type Platform, type ThemeMode } from '../../lib/PlatformContext'
import { ThemeProvider } from '@mui/material/styles'
import CssBaseline from '@mui/material/CssBaseline'
import { useMuiTheme } from '../../lib/muiTheme'
import { useStartSession } from '../../lib/StartSessionContext'
import { useBlocks } from '../../lib/useBlocks'
import ScriptIcon from '../shared/ScriptIcon'
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
  const { showRedlines, setShowRedlines, inspectorOpen, setInspectorOpen } = useRedlines()
  return (
    <div
      className="sticky top-0 z-10 border-b"
      style={{
        background: 'rgba(245,245,247,0.92)',
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
        borderColor: 'rgba(0,0,0,0.1)',
      }}
    >
      {/* Main row */}
      <div className="flex items-center justify-center gap-3 px-6 py-2.5">
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
        <button
          onClick={() => setShowRedlines(!showRedlines)}
          className="flex items-center gap-1.5 px-3 py-1 rounded-md text-[12px] font-semibold transition-all"
          style={{
            background: showRedlines ? 'rgba(255,45,85,0.12)' : 'rgba(0,0,0,0.06)',
            color: showRedlines ? 'rgb(255,45,85)' : 'rgba(0,0,0,0.5)',
          }}
        >
          <FrameCorners size={13} weight={showRedlines ? 'bold' : 'regular'} />
          Redlines
        </button>
        <button
          onClick={() => setInspectorOpen(!inspectorOpen)}
          className="flex items-center gap-1.5 px-3 py-1 rounded-md text-[12px] font-semibold transition-all"
          style={{
            background: inspectorOpen ? 'rgba(0,122,255,0.12)' : 'rgba(0,0,0,0.06)',
            color: inspectorOpen ? '#007aff' : 'rgba(0,0,0,0.5)',
          }}
        >
          <Code size={13} weight={inspectorOpen ? 'bold' : 'regular'} />
          Inspector
        </button>
      </div>

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

// iOS nav bar style — transparent, content floats over the gradient
export function iosGlassStyle(_isLight: boolean) {
  return { background: 'transparent' } as const
}

// iOS 26 glass pill — for Back buttons, action buttons
export function iosGlassPill(isLight: boolean) {
  return isLight
    ? {
        backdropFilter: 'blur(12px) saturate(1.5)',
        WebkitBackdropFilter: 'blur(12px) saturate(1.5)',
        background: 'rgba(255,255,255,0.22)',
        borderRadius: 20,
        boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.8), 0 1px 4px rgba(0,0,0,0.08)',
      }
    : {
        backdropFilter: 'blur(12px) saturate(1.5)',
        WebkitBackdropFilter: 'blur(12px) saturate(1.5)',
        background: 'rgba(255,255,255,0.13)',
        borderRadius: 20,
        boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.22), 0 1px 4px rgba(0,0,0,0.2)',
      }
}

function IOSStatusBar() {
  const time = new Date().toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true })
  return (
    <div className="flex-shrink-0 relative flex items-center justify-between px-6 h-12">
      <span className="text-[15px] font-semibold text-ask-text tabular-nums">{time}</span>
      {/* Dynamic Island */}
      <div className="absolute left-1/2 top-2 -translate-x-1/2 w-[120px] h-[34px] bg-black rounded-full" />
      {/* Signal bars / wifi / battery icons */}
      <div className="flex items-center gap-[5px] text-ask-text">
        <span className="mat-icon" style={{ fontSize: 16, fontVariationSettings: "'FILL' 1, 'wght' 400, 'opsz' 16" }}>signal_cellular_alt</span>
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
  const { scriptGroups } = useBlocks()
  const [popoverOpen, setPopoverOpen] = useState(false)
  const [bellOpen, setBellOpen] = useState(false)

  // Alert groups: scripts with inbox blocks OR a pending agent session confirmation
  const alertGroups = Object.entries(scriptGroups).reduce<
    Record<string, { scriptName: string; count: number; scriptIconSVG?: string; scriptIconData?: string; scriptIcon?: string }>
  >((acc, [scriptID, sBlocks]) => {
    const inboxCount = sBlocks.filter(b => b.showsInInbox === 1).length
    const hasPending = sBlocks.some(b => {
      if (b.blockType !== 'agent_session') return false
      try {
        const p = JSON.parse(b.payload) as { pending_confirmation?: unknown }
        return !!p.pending_confirmation
      } catch { return false }
    })
    if (inboxCount > 0 || hasPending) {
      const first = sBlocks[0]
      acc[scriptID] = {
        scriptName: first?.scriptName ?? scriptID,
        count: inboxCount + (hasPending ? 1 : 0),
        scriptIconSVG: first?.scriptIconSVG,
        scriptIconData: first?.scriptIconData,
        scriptIcon: first?.scriptIcon,
      }
    }
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
          {Object.entries(alertGroups).map(([scriptID, { scriptName, count, scriptIconSVG, scriptIconData, scriptIcon }], i, arr) => (
            <button
              key={scriptID}
              onClick={() => { navigate('/home'); setBellOpen(false) }}
              className={`w-full flex items-center gap-3 px-4 py-2.5 text-left hover:bg-white/10 transition-colors ${
                i < arr.length - 1 ? 'border-b' : ''
              }`}
              style={{ borderColor: isLight ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.08)' }}
            >
              <ScriptIcon scriptIconSVG={scriptIconSVG} scriptIconData={scriptIconData} scriptIcon={scriptIcon} scriptName={scriptName} size={22} />
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
              <FolderOpen size={18} style={{ color: iconColor, flexShrink: 0 }} />
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
            style={{ color: iconColor, width: 24, height: 24 }}
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
  const [dialogOpen, setDialogOpen] = useState(false)

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
  return (
    <RedlinesProvider>
      <AppShellInner>{children}</AppShellInner>
    </RedlinesProvider>
  )
}

function AppShellInner({ children }: Props) {
  const location = useLocation()
  const { platform, themeMode } = usePlatform()
  const isAndroid = platform === 'android'
  const isLight = themeMode === 'light'
  const muiTheme = useMuiTheme()
  const [brandColor, setBrandColor] = useState<string | null>(null)
  const { inspectorOpen, showRedlines } = useRedlines()

  const phoneAreaRef = useRef<HTMLDivElement>(null)
  const scale = usePhoneScale(phoneAreaRef)

  const tab = location.pathname.startsWith('/tasks') ? 'tasks'
    : location.pathname.startsWith('/settings') ? 'settings'
    : 'home'

  const hideIOSTabBar = location.pathname.includes('/session/')

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
    <div className="h-screen flex flex-col overflow-hidden" style={{ background: '#f5f5f7' }}>
      <ControlBar />

      {/* Phone area */}
      <div ref={phoneAreaRef} className="flex-1 flex items-start justify-center py-8 px-8 overflow-hidden" style={{ position: 'relative' }}>
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
              id="phone-screen"
              className={`flex flex-col ${isAndroid ? 'platform-android' : ''} ${isLight ? 'theme-light' : ''}`}
              style={{
                position: 'relative',
                width: 390,
                height: 844,
                borderRadius: innerRadius,
                overflow: 'hidden',
                background: !isAndroid && brandColor
                  ? `linear-gradient(180deg, ${brandColor}55 0%, ${brandColor}22 180px, ${isLight ? 'rgb(242,242,247)' : 'rgb(28,28,30)'} 360px)`
                  : (isAndroid
                      ? (isLight ? 'rgb(255 251 254)' : 'rgb(20 18 24)')
                      : (isLight ? 'rgb(242 242 247)' : 'rgb(28 28 30)')),
              }}
            >
              {isAndroid ? <AndroidStatusBar /> : <IOSStatusBar />}

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
                : !hideIOSTabBar && <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0 }}><IOSTabBar tab={tab} isLight={isLight} /></div>
              }
            </div>
          </div>

          {/* SVG redlines overlay — sits over phone screen, overflow:visible draws annotations outside */}
          <RedlinesOverlay framePad={framePad} />
        </div>

        {/* Side panels — fixed to viewport right edge, stacked vertically, don't affect phone position */}
        <div style={{ position: 'fixed', top: 108, right: 16, zIndex: 50, display: 'flex', flexDirection: 'column', gap: 12, maxHeight: 'calc(100vh - 120px)', overflowY: 'auto' }}>
          {inspectorOpen && <UIInspectorPanel />}
          {showRedlines && <RedlinesDetailPanel />}
        </div>
      </div>
    </div>
  )
}
