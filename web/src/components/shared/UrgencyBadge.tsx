import type { Urgency } from '../../lib/types'

interface Props { urgency?: Urgency }

export default function UrgencyBadge({ urgency = 'warning' }: Props) {
  const config = {
    urgent:  { label: '!', bg: 'bg-ask-red/20',    text: 'text-ask-red',    border: 'border-ask-red/40' },
    warning: { label: '~', bg: 'bg-ask-orange/20', text: 'text-ask-orange', border: 'border-ask-orange/40' },
    info:    { label: 'i', bg: 'bg-ask-secondary/20', text: 'text-ask-secondary', border: 'border-ask-secondary/40' },
  }[urgency]

  return (
    <span className={`inline-flex items-center justify-center w-5 h-5 rounded text-[10px] font-bold border ${config.bg} ${config.text} ${config.border}`}>
      {config.label}
    </span>
  )
}
