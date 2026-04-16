interface Props {
  scriptIconData?: string
  scriptIconSVG?: string
  scriptIcon?: string
  scriptName: string
  size?: number
}

export default function ScriptIcon({ scriptIconData, scriptIconSVG, scriptIcon, scriptName, size = 36 }: Props) {
  const style = { width: size, height: size, flexShrink: 0 }

  if (scriptIconData) {
    return (
      <img
        src={`data:image/png;base64,${scriptIconData}`}
        alt={scriptName}
        style={{ ...style, objectFit: 'contain' }}
        className="rounded-xl"
      />
    )
  }

  if (scriptIconSVG) {
    // Normalize the SVG regardless of where it came from (fixture loader or
    // live AskMac snapshot):
    //  1. Strip inline style / width / height from the root <svg> so we control sizing.
    //  2. Replace hardcoded black fills with currentColor for light/dark theme support.
    let svg = scriptIconSVG
      .replace(/(<svg[^>]*?)\s+(width|height|style)="[^"]*"/g, '$1')
      .replace('<svg', '<svg width="100%" height="100%" style="display:block"')
      .replace(/fill="(#000000|#000|black)"/gi, 'fill="currentColor"')

    // text-ask-text sets currentColor to the theme text color (white in dark, black in light).
    // [&>svg]:* forces the injected SVG to fill the container div.
    return (
      <div
        style={style}
        className="rounded-xl overflow-hidden text-ask-text [&>svg]:block [&>svg]:w-full [&>svg]:h-full"
        dangerouslySetInnerHTML={{ __html: svg }}
      />
    )
  }

  // Unicode emoji icon
  if (scriptIcon) {
    return (
      <div style={{ ...style, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <span style={{ fontSize: size * 0.72, lineHeight: 1 }}>{scriptIcon}</span>
      </div>
    )
  }

  // Text fallback — initials
  const initials = scriptName
    .split(/\s+/)
    .slice(0, 2)
    .map(w => w[0]?.toUpperCase() ?? '')
    .join('')

  return (
    <div
      style={style}
      className="rounded-xl bg-ask-card2 flex items-center justify-center text-[11px] font-semibold text-ask-secondary"
    >
      {initials}
    </div>
  )
}
