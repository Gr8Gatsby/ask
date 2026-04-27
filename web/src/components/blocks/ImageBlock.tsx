interface Props {
  payload: { title: string; data: string; format?: string }
}

export default function ImageBlock({ payload }: Props) {
  const src = `data:image/${payload.format ?? 'png'};base64,${payload.data}`
  return (
    <div className="flex flex-col gap-2">
      <p className="text-xs text-ask-secondary truncate">{payload.title}</p>
      <img
        src={src}
        alt={payload.title}
        className="w-full rounded-lg border border-ask-sep/30"
      />
    </div>
  )
}
