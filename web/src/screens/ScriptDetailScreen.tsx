import { useNavigate, useParams } from 'react-router-dom'
import { useEffect } from 'react'
import { useBlocks } from '../lib/useBlocks'
import { useTheme } from '../lib/PlatformContext'
import { useSettings } from '../lib/SettingsContext'
import type { AgentSessionPayload, ConfirmationPayload } from '../lib/types'
import BlockRenderer from '../components/blocks/BlockRenderer'
import ScriptIcon from '../components/shared/ScriptIcon'
import { useStartSession } from '../lib/StartSessionContext'
import { useBrandColor } from '../components/layout/AppShell'

function parsePayload<T>(json: string): T | null {
  try { return JSON.parse(json) as T } catch { return null }
}

// ---- Session row ----

function SessionRow({
  block,
  confirmationCount,
  onClick,
  isAndroid,
}: {
  block: ReturnType<typeof useBlocks>['blocks'][number]
  confirmationCount: number
  onClick: () => void
  isAndroid: boolean
}) {
  const payload = parsePayload<AgentSessionPayload>(block.payload)
  if (!payload) return null

  return (
    <button
      onClick={onClick}
      className={`w-full flex items-center gap-3 py-3 transition-colors text-left ${
        isAndroid ? 'hover:bg-white/5' : 'px-4 hover:bg-ask-card2/60'
      }`}
    >
      <div
        className={`w-2 h-2 rounded-full flex-shrink-0 ${payload.is_working ? 'bg-ask-blue animate-pulse' : 'bg-ask-card2'}`}
      />
      <div className="flex-1 min-w-0">
        <p className="text-sm font-semibold text-ask-text">{payload.project}</p>
        <p className="text-xs text-ask-secondary truncate">
          {payload.is_working
            ? `${payload.agent_name ?? 'Claude'} is working…`
            : (payload.last_message?.split('\n').find(l => l.trim()) ?? 'Session started')}
        </p>
      </div>
      <div className="flex items-center gap-2 flex-shrink-0">
        {confirmationCount > 0 && (
          <span className="text-[10px] font-bold bg-ask-orange/20 text-ask-orange px-1.5 py-0.5 rounded-full min-w-[20px] text-center">
            {confirmationCount}
          </span>
        )}
        <span className="text-ask-secondary">›</span>
      </div>
    </button>
  )
}

// ---- Screen ----

export default function ScriptDetailScreen() {
  const { scriptID } = useParams<{ scriptID: string }>()
  const navigate = useNavigate()
  const theme = useTheme()
  const { blocks: allBlocks, respond } = useBlocks()
  const { setAction } = useStartSession()
  const { useBrandColors } = useSettings()
  const { setBrandColor: setAppBrandColor } = useBrandColor()
  const blocks = allBlocks.filter(b => b.scriptID === scriptID)
  const first = blocks[0]

  const sessionBlocks = blocks.filter(b => b.blockType === 'agent_session')
  const liveSessionIDs = new Set(
    sessionBlocks.map(b => parsePayload<AgentSessionPayload>(b.payload)?.session_id ?? '')
  )

  const headerBlocks = blocks.filter(b => {
    if (['agent_session', 'tile', 'start_session', 'feed_item'].includes(b.blockType)) return false
    if (b.blockType === 'confirmation') {
      const sid = parsePayload<ConfirmationPayload>(b.payload)?.session_id
      if (sid && liveSessionIDs.has(sid)) return false
    }
    return true
  })

  const startSessionBlock = blocks.find(b => b.blockType === 'start_session')
  const brandColor = useBrandColors
    ? (parsePayload<AgentSessionPayload>(sessionBlocks[0]?.payload)?.brand_color ?? null)
    : null

  // Push brand color up to AppShell so the iOS status bar tints to match
  useEffect(() => {
    if (!theme.isAndroid) setAppBrandColor(brandColor)
    return () => setAppBrandColor(null)
  }, [brandColor, theme.isAndroid]) // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (startSessionBlock) {
      setAction({ block: startSessionBlock, payload: JSON.parse(startSessionBlock.payload), respond })
    } else {
      setAction(null)
    }
    return () => setAction(null)
  }, [startSessionBlock?.blockID]) // eslint-disable-line react-hooks/exhaustive-deps

  function sessionConfirmations(sessionId: string) {
    return blocks.filter(b => {
      if (b.blockType !== 'confirmation') return false
      return parsePayload<ConfirmationPayload>(b.payload)?.session_id === sessionId
    })
  }

  const isEmpty = headerBlocks.length === 0 && sessionBlocks.length === 0

  return (
    <div className="flex flex-col h-full">
      {/* Nav bar — iOS: no border, blends into frosted status bar; Android: border-b */}
      <div
        className={`flex items-center gap-3 px-4 pt-3 pb-3 flex-shrink-0 ${
          theme.isAndroid ? 'border-b border-ask-sep/50' : ''
        }`}
      >
        <button onClick={() => navigate(-1)} className={theme.navBackClass}>
          {theme.navBackIcon}
          {!theme.isAndroid && <span>Home</span>}
        </button>
        {first && (
          <div className="flex items-center gap-2 flex-1 min-w-0">
            <ScriptIcon
              scriptIconData={first.scriptIconData}
              scriptIconSVG={first.scriptIconSVG}
              scriptIcon={first.scriptIcon}
              scriptName={first.scriptName}
              size={24}
            />
            <span className={`${theme.typeTitleMedium} text-ask-text truncate`}>{first.scriptName}</span>
          </div>
        )}
      </div>

      {/* Scrollable content */}
      <div className="flex-1 overflow-y-auto no-scrollbar">
        {isEmpty ? (
          <div className="flex items-center justify-center h-40 text-ask-secondary text-sm">No active blocks</div>
        ) : (
          <div className="flex flex-col">
            {/* Header blocks */}
            {headerBlocks.map(block => (
              <div key={block.blockID} className="px-4 py-3 border-b border-ask-sep">
                <BlockRenderer block={block} onRespond={respond} />
              </div>
            ))}

            {/* Sessions section */}
            {sessionBlocks.length > 0 && (
              <div className={theme.isAndroid ? 'mt-1' : 'mt-4 px-4'}>
                <p className={`pb-1 ${theme.isAndroid ? 'px-4 pt-3' : 'pt-0 pb-2'} ${theme.sectionHeader}`}>
                  {theme.isAndroid ? 'Sessions' : 'SESSIONS'}
                </p>

                {/* iOS: inset-grouped card; Android: flat full-width list */}
                <div className={theme.isAndroid
                  ? ''
                  : 'bg-ask-card rounded-xl overflow-hidden border border-ask-sep/40'
                }>
                  {sessionBlocks.map((block, idx) => {
                    const payload = parsePayload<AgentSessionPayload>(block.payload)
                    const confs = payload ? sessionConfirmations(payload.session_id) : []
                    const isLast = idx === sessionBlocks.length - 1
                    return (
                      <div key={block.blockID}>
                        <div className={
                          theme.isAndroid
                            ? `px-4 border-b border-ask-sep ${confs.length > 0 ? 'bg-ask-orange/5' : ''}`
                            : `${confs.length > 0 ? 'bg-ask-orange/5' : ''} ${!isLast || confs.length > 0 ? 'border-b border-ask-sep/40' : ''}`
                        }>
                          <SessionRow
                            block={block}
                            confirmationCount={confs.length}
                            isAndroid={theme.isAndroid}
                            onClick={() => {
                              if (payload) navigate(`/script/${scriptID}/session/${payload.session_id}`)
                            }}
                          />
                        </div>

                        {/* Linked confirmations — indented, orange tint */}
                        {confs.map((conf, ci) => (
                          <div
                            key={conf.blockID}
                            className={`pl-8 pr-4 py-3 bg-ask-orange/5 ${
                              theme.isAndroid
                                ? 'border-b border-ask-sep'
                                : (!isLast || ci < confs.length - 1 ? 'border-b border-ask-sep/40' : '')
                            }`}
                          >
                            <BlockRenderer block={conf} onRespond={respond} />
                          </div>
                        ))}
                      </div>
                    )
                  })}
                </div>
              </div>
            )}
          </div>
        )}
      </div>

    </div>
  )
}
