import type { AlertPayload } from '../../lib/types'
import { useTheme, PlatformIcon } from '../../lib/PlatformContext'

interface Props { payload: AlertPayload }

export default function AlertBlock({ payload }: Props) {
  const theme = useTheme()

  const urgency = payload.urgency ?? 'info'
  const icon = urgency === 'urgent'
    ? { ios: '⚠', android: 'error', color: 'text-ask-red' }
    : urgency === 'warning'
    ? { ios: '⚠', android: 'warning', color: 'text-ask-orange' }
    : { ios: 'ℹ', android: 'info', color: 'text-ask-blue' }

  if (theme.isAndroid) {
    // Android M3: banner-style alert — left accent icon, bodyMedium text
    return (
      <div className="flex items-start gap-3 px-1">
        <PlatformIcon
          ios={icon.ios}
          android={icon.android}
          fill
          size={22}
          className={`flex-shrink-0 mt-0.5 ${icon.color}`}
        />
        <div className="flex-1 min-w-0">
          <p className={`${theme.typeBodyLarge} text-ask-text`}>{payload.title}</p>
          {payload.body && (
            <p className={`${theme.typeBodyMedium} text-ask-secondary mt-1`}>{payload.body}</p>
          )}
        </div>
      </div>
    )
  }

  // iOS: HStack icon + VStack(title, body) — footnote/caption2
  return (
    <div className="flex items-start gap-2">
      <PlatformIcon
        ios={icon.ios}
        android={icon.android}
        fill
        size={17}
        className={`flex-shrink-0 mt-0.5 ${icon.color}`}
      />
      <div className="flex-1 min-w-0">
        {/* iOS footnote (13pt) semibold title */}
        <p className="text-[13px] font-semibold text-ask-text leading-snug">{payload.title}</p>
        {payload.body && (
          /* iOS caption2 (11pt) secondary body */
          <p className="text-[11px] font-normal text-ask-secondary mt-[2px] leading-relaxed">{payload.body}</p>
        )}
      </div>
    </div>
  )
}
