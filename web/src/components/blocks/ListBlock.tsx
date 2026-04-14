import type { Block, ListPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props {
  block: Block
  payload: ListPayload
  onRespond: (blockID: string, value: string) => void
}

export default function ListBlock({ block, payload, onRespond }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    return (
      <div className="flex flex-col gap-1">
        {payload.title && (
          <p className="text-[16px] font-medium text-ask-text leading-6 pb-1">{payload.title}</p>
        )}
        <div>
          {payload.items.map((item, i) => (
            <div key={item.id}>
              {i > 0 && <div className="h-px bg-ask-sep/30" />}
              <button
                onClick={() => onRespond(block.blockID, item.id)}
                className="w-full flex items-center gap-3 min-h-[56px] px-0 active:bg-ask-text/[0.05] transition-colors text-left"
              >
                <div className="flex-1 min-w-0">
                  <p className="text-[16px] text-ask-text leading-6">{item.label}</p>
                  {item.subtitle && (
                    <p className="text-[14px] text-ask-secondary leading-5">{item.subtitle}</p>
                  )}
                </div>
                <span className="mat-icon text-ask-secondary flex-shrink-0" style={{ fontSize: 20, fontVariationSettings: "'FILL' 0, 'wght' 400, 'opsz' 20" }}>chevron_right</span>
              </button>
            </div>
          ))}
        </div>
        {payload.actions && payload.actions.length > 0 && (
          <div className="flex flex-col gap-2 pt-1">
            {payload.actions.map(action => (
              <button
                key={action}
                onClick={() => onRespond(block.blockID, action)}
                className="w-full min-h-[40px] rounded-full border border-ask-blue text-ask-blue text-[14px] font-medium tracking-[0.1px] active:bg-ask-blue/10 transition-colors"
              >
                {action}
              </button>
            ))}
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-2">
      {payload.title && <p className="text-sm font-semibold text-ask-text">{payload.title}</p>}
      <div className="border-t border-ask-sep">
        {payload.items.map(item => (
          <button key={item.id} onClick={() => onRespond(block.blockID, item.id)} className="w-full flex items-center justify-between py-2.5 border-b border-ask-sep last:border-0 hover:bg-ask-text/[0.05] transition-colors text-left px-0.5">
            <div>
              <p className="text-sm text-ask-text">{item.label}</p>
              {item.subtitle && <p className="text-xs text-ask-secondary">{item.subtitle}</p>}
            </div>
            <span className="text-ask-secondary text-sm">›</span>
          </button>
        ))}
      </div>
      {payload.actions && payload.actions.length > 0 && (
        <div className="flex flex-col gap-2 pt-1">
          {payload.actions.map(action => (
            <button key={action} onClick={() => onRespond(block.blockID, action)} className="w-full py-2 rounded-lg bg-ask-card2 text-sm font-medium text-ask-text hover:bg-ask-card2/60 transition-colors">{action}</button>
          ))}
        </div>
      )}
    </div>
  )
}
