interface Props {
  scriptIconData?: string
  scriptIconSVG?: string
  scriptIcon?: string
  scriptName: string
  size?: number
}

export default function ScriptIcon({ scriptIconData, scriptIconSVG, scriptIcon: _scriptIcon, scriptName, size = 28 }: Props) {
  const style = { width: size, height: size }

  if (scriptIconData) {
    return (
      <img
        src={`data:image/png;base64,${scriptIconData}`}
        alt={scriptName}
        style={style}
        className="rounded-md"
      />
    )
  }

  if (scriptIconSVG) {
    return (
      <div
        style={style}
        className="rounded-md overflow-hidden flex items-center justify-center"
        dangerouslySetInnerHTML={{ __html: scriptIconSVG }}
      />
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
      className="rounded-md bg-ask-card2 flex items-center justify-center text-[10px] font-semibold text-ask-secondary"
    >
      {initials}
    </div>
  )
}
