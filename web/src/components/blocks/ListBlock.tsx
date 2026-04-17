import React from 'react'
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

  // iOS — inset grouped card style
  return (
    <div className="flex flex-col gap-2">
      {payload.title && <p className="text-[13px] font-semibold text-ask-secondary uppercase tracking-wide px-1 pb-0.5">{payload.title}</p>}
      <div className="bg-ask-card rounded-xl overflow-hidden shadow-sm shadow-black/[0.06]">
        {payload.items.map((item, i) => (
          <React.Fragment key={item.id}>
            {i > 0 && <div className="h-px bg-ask-sep/50 ml-4 mr-4" />}
            <button
              onClick={() => onRespond(block.blockID, item.id)}
              className="w-full flex items-center justify-between min-h-[44px] px-4 active:bg-ask-sep/30 transition-colors text-left"
            >
              <div className="flex-1 min-w-0">
                <p className="text-[17px] text-ask-text">{item.label}</p>
                {item.subtitle && <p className="text-[13px] text-ask-secondary">{item.subtitle}</p>}
              </div>
              <svg width="6" height="10" viewBox="0 0 6 10" fill="none" className="ml-2 text-ask-secondary/45 flex-shrink-0">
                <path d="M1 1l4 4-4 4" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </button>
          </React.Fragment>
        ))}
      </div>
      {payload.actions && payload.actions.length > 0 && (
        <div className="flex flex-col gap-2 pt-1">
          {payload.actions.map(action => (
            <button key={action} onClick={() => onRespond(block.blockID, action)} className="w-full py-3 rounded-xl bg-ask-card text-[17px] text-ask-blue font-normal active:bg-ask-sep/30 transition-colors shadow-sm shadow-black/[0.06]">{action}</button>
          ))}
        </div>
      )}
    </div>
  )
}
