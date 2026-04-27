import type { Block } from '../../lib/types'
import ConfirmationBlock from './ConfirmationBlock'
import AlertBlock from './AlertBlock'
import StatusBlock from './StatusBlock'
import PromptBlock from './PromptBlock'
import ChatPromptBlock from './ChatPromptBlock'
import ClaudeMessageBlock from './ClaudeMessageBlock'
import AgentSessionBlock from './AgentSessionBlock'
import StartSessionBlock from './StartSessionBlock'
import InfoCardBlock from './InfoCardBlock'
import IconCardBlock from './IconCardBlock'
import CompactSummaryBlock from './CompactSummaryBlock'
import CountdownBlock from './CountdownBlock'
import PickerBlock from './PickerBlock'
import ListBlock from './ListBlock'
import DetailBlock from './DetailBlock'
import FeedItemBlock from './FeedItemBlock'
import QuickReplyBlock from './QuickReplyBlock'
import SessionEventBlock from './SessionEventBlock'
import ActivityFeedBlock from './ActivityFeedBlock'
import ImageBlock from './ImageBlock'

interface Props {
  block: Block
  onRespond: (blockID: string, value: string) => void
  showDebugInfo?: boolean
}

function DebugBar({ block }: { block: Block }) {
  const ts = new Date(block.createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  return (
    <div className="flex flex-wrap gap-x-3 gap-y-0.5 px-2 py-1 bg-black/60 text-[10px] font-mono text-ask-secondary border-b border-ask-sep/20">
      <span><span className="text-ask-secondary/50">id </span>{block.blockID.slice(0, 8)}…</span>
      <span><span className="text-ask-secondary/50">type </span>{block.blockType}</span>
      <span><span className="text-ask-secondary/50">machine </span>{block.machineID.slice(0, 8)}…</span>
      <span><span className="text-ask-secondary/50">at </span>{ts}</span>
    </div>
  )
}

function wrap(blockID: string, blockType: string, node: React.ReactNode, debugBar?: React.ReactNode) {
  if (node === null) return null
  return (
    <div data-block-id={blockID} data-block-type={blockType}>
      {debugBar}
      {node}
    </div>
  )
}

export default function BlockRenderer({ block, onRespond, showDebugInfo }: Props) {
  let payload: unknown
  try { payload = JSON.parse(block.payload) } catch { payload = {} }

  const p = payload as Record<string, unknown>
  const dbg = showDebugInfo ? <DebugBar block={block} /> : undefined

  switch (block.blockType) {
    case 'confirmation':   return wrap(block.blockID, block.blockType, <ConfirmationBlock  block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'alert':          return wrap(block.blockID, block.blockType, <AlertBlock          payload={p as never} />, dbg)
    case 'status':         return wrap(block.blockID, block.blockType, <StatusBlock         payload={p as never} />, dbg)
    case 'prompt':         return wrap(block.blockID, block.blockType, <PromptBlock         block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'chat_prompt':    return wrap(block.blockID, block.blockType, <ChatPromptBlock     block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'claude_message': return wrap(block.blockID, block.blockType, <ClaudeMessageBlock  block={block} payload={p as never} />, dbg)
    case 'agent_session':  return wrap(block.blockID, block.blockType, <AgentSessionBlock   block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'start_session':  return wrap(block.blockID, block.blockType, <StartSessionBlock   block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'info_card':      return wrap(block.blockID, block.blockType, <InfoCardBlock        payload={p as never} />, dbg)
    case 'icon_card':      return wrap(block.blockID, block.blockType, <IconCardBlock        payload={p as never} />, dbg)
    case 'compact_summary': return wrap(block.blockID, block.blockType, <CompactSummaryBlock payload={p as never} />, dbg)
    case 'countdown':      return wrap(block.blockID, block.blockType, <CountdownBlock       payload={p as never} />, dbg)
    case 'picker':         return wrap(block.blockID, block.blockType, <PickerBlock          block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'list':           return wrap(block.blockID, block.blockType, <ListBlock            block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'detail':         return wrap(block.blockID, block.blockType, <DetailBlock          block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'feed_item':      return wrap(block.blockID, block.blockType, <FeedItemBlock        payload={p as never} />, dbg)
    case 'quick_reply':    return wrap(block.blockID, block.blockType, <QuickReplyBlock      block={block} payload={p as never} onRespond={onRespond} />, dbg)
    case 'session_event':  return wrap(block.blockID, block.blockType, <SessionEventBlock    payload={p as never} />, dbg)
    case 'activity_feed':  return wrap(block.blockID, block.blockType, <ActivityFeedBlock    payload={p as never} />, dbg)
    case 'image':         return wrap(block.blockID, block.blockType, <ImageBlock          payload={p as never} />, dbg)
    case 'tile':           return null  // Tile blocks render only as home-screen tiles, not in block list
    default:
      return wrap(block.blockID, block.blockType,
        <div className="flex items-center gap-2 text-ask-secondary">
          <span className="text-xs font-mono bg-ask-card2 px-1.5 py-0.5 rounded">{block.blockType}</span>
          <span className="text-xs">— not yet implemented</span>
        </div>,
        dbg
      )
  }
}
