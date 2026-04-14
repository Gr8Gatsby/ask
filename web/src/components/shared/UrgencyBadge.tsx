import type { Urgency } from '../../lib/types'

interface Props { urgency?: Urgency }

// Matches iOS: [!] red / [~] orange / [i] gray, monospace
export default function UrgencyBadge({ urgency = 'warning' }: Props) {
  const config = {
    urgent:  { label: '[!]', color: 'text-ask-red',       bg: 'bg-ask-red/15' },
    warning: { label: '[~]', color: 'text-ask-orange',    bg: 'bg-ask-orange/15' },
    info:    { label: '[i]', color: 'text-ask-secondary', bg: 'bg-ask-secondary/15' },
  }[urgency]

  return (
    <span className={`font-mono text-[10px] font-bold px-1 py-0.5 rounded ${config.color} ${config.bg}`}>
      {config.label}
    </span>
  )
}
