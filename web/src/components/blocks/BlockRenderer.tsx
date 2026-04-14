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

interface Props {
  block: Block
  onRespond: (blockID: string, value: string) => void
}

export default function BlockRenderer({ block, onRespond }: Props) {
  let payload: unknown
  try { payload = JSON.parse(block.payload) } catch { payload = {} }

  const p = payload as Record<string, unknown>

  switch (block.blockType) {
    case 'confirmation':   return <ConfirmationBlock  block={block} payload={p as never} onRespond={onRespond} />
    case 'alert':          return <AlertBlock          payload={p as never} />
    case 'status':         return <StatusBlock         payload={p as never} />
    case 'prompt':         return <PromptBlock         block={block} payload={p as never} onRespond={onRespond} />
    case 'chat_prompt':    return <ChatPromptBlock     block={block} payload={p as never} onRespond={onRespond} />
    case 'claude_message': return <ClaudeMessageBlock  block={block} payload={p as never} />
    case 'agent_session':  return <AgentSessionBlock   block={block} payload={p as never} onRespond={onRespond} />
    case 'start_session':  return <StartSessionBlock   block={block} payload={p as never} onRespond={onRespond} />
    case 'info_card':      return <InfoCardBlock        payload={p as never} />
    case 'icon_card':      return <IconCardBlock        payload={p as never} />
    case 'compact_summary': return <CompactSummaryBlock payload={p as never} />
    case 'countdown':      return <CountdownBlock       payload={p as never} />
    case 'picker':         return <PickerBlock          block={block} payload={p as never} onRespond={onRespond} />
    case 'list':           return <ListBlock            block={block} payload={p as never} onRespond={onRespond} />
    case 'detail':         return <DetailBlock          block={block} payload={p as never} onRespond={onRespond} />
    case 'feed_item':      return <FeedItemBlock        payload={p as never} />
    case 'quick_reply':    return <QuickReplyBlock      block={block} payload={p as never} onRespond={onRespond} />
    case 'session_event':  return <SessionEventBlock    payload={p as never} />
    case 'activity_feed':  return <ActivityFeedBlock    payload={p as never} />
    case 'tile':           return null  // Tile blocks render only as home-screen tiles, not in block list
    default:
      return (
        <div className="flex items-center gap-2 text-ask-secondary">
          <span className="text-xs font-mono bg-ask-card2 px-1.5 py-0.5 rounded">{block.blockType}</span>
          <span className="text-xs">— not yet implemented</span>
        </div>
      )
  }
}
