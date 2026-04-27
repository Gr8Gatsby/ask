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
}

function wrap(blockID: string, blockType: string, node: React.ReactNode) {
  if (node === null) return null
  return <div data-block-id={blockID} data-block-type={blockType}>{node}</div>
}

export default function BlockRenderer({ block, onRespond }: Props) {
  let payload: unknown
  try { payload = JSON.parse(block.payload) } catch { payload = {} }

  const p = payload as Record<string, unknown>

  switch (block.blockType) {
    case 'confirmation':   return wrap(block.blockID, block.blockType, <ConfirmationBlock  block={block} payload={p as never} onRespond={onRespond} />)
    case 'alert':          return wrap(block.blockID, block.blockType, <AlertBlock          payload={p as never} />)
    case 'status':         return wrap(block.blockID, block.blockType, <StatusBlock         payload={p as never} />)
    case 'prompt':         return wrap(block.blockID, block.blockType, <PromptBlock         block={block} payload={p as never} onRespond={onRespond} />)
    case 'chat_prompt':    return wrap(block.blockID, block.blockType, <ChatPromptBlock     block={block} payload={p as never} onRespond={onRespond} />)
    case 'claude_message': return wrap(block.blockID, block.blockType, <ClaudeMessageBlock  block={block} payload={p as never} />)
    case 'agent_session':  return wrap(block.blockID, block.blockType, <AgentSessionBlock   block={block} payload={p as never} onRespond={onRespond} />)
    case 'start_session':  return wrap(block.blockID, block.blockType, <StartSessionBlock   block={block} payload={p as never} onRespond={onRespond} />)
    case 'info_card':      return wrap(block.blockID, block.blockType, <InfoCardBlock        payload={p as never} />)
    case 'icon_card':      return wrap(block.blockID, block.blockType, <IconCardBlock        payload={p as never} />)
    case 'compact_summary': return wrap(block.blockID, block.blockType, <CompactSummaryBlock payload={p as never} />)
    case 'countdown':      return wrap(block.blockID, block.blockType, <CountdownBlock       payload={p as never} />)
    case 'picker':         return wrap(block.blockID, block.blockType, <PickerBlock          block={block} payload={p as never} onRespond={onRespond} />)
    case 'list':           return wrap(block.blockID, block.blockType, <ListBlock            block={block} payload={p as never} onRespond={onRespond} />)
    case 'detail':         return wrap(block.blockID, block.blockType, <DetailBlock          block={block} payload={p as never} onRespond={onRespond} />)
    case 'feed_item':      return wrap(block.blockID, block.blockType, <FeedItemBlock        payload={p as never} />)
    case 'quick_reply':    return wrap(block.blockID, block.blockType, <QuickReplyBlock      block={block} payload={p as never} onRespond={onRespond} />)
    case 'session_event':  return wrap(block.blockID, block.blockType, <SessionEventBlock    payload={p as never} />)
    case 'activity_feed':  return wrap(block.blockID, block.blockType, <ActivityFeedBlock    payload={p as never} />)
    case 'image':         return wrap(block.blockID, block.blockType, <ImageBlock          payload={p as never} />)
    case 'tile':           return null  // Tile blocks render only as home-screen tiles, not in block list
    default:
      return wrap(block.blockID, block.blockType,
        <div className="flex items-center gap-2 text-ask-secondary">
          <span className="text-xs font-mono bg-ask-card2 px-1.5 py-0.5 rounded">{block.blockType}</span>
          <span className="text-xs">— not yet implemented</span>
        </div>
      )
  }
}
