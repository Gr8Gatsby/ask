// Block record — mirrors RKBlockRecord in CloudKitSchema.swift
export interface Block {
  blockID: string
  machineID: string
  scriptID: string
  scriptName: string
  scriptIcon?: string
  scriptIconData?: string
  scriptIconSVG?: string
  blockType: BlockType
  payload: string  // JSON string — decode per blockType
  createdAt: string
  expiresAt?: string
  scriptType: 'tile' | 'feed'
  requiresResponse: number  // 1 | 0
  showsInInbox: number
}

export type BlockType =
  | 'confirmation' | 'alert' | 'status' | 'prompt' | 'chat_prompt'
  | 'claude_message' | 'agent_session' | 'start_session' | 'info_card'
  | 'icon_card' | 'tile' | 'countdown' | 'picker' | 'list' | 'detail'
  | 'feed_item' | 'quick_reply' | 'progress' | 'log' | 'image'
  | 'multi_select' | 'toggle'
  | 'session_event' | 'activity_feed' | 'compact_summary' | 'diagnostics'

// ---- Payload types (mirrors RemoteKitModels.swift) ----

export interface ConfirmationPayload {
  title: string
  body: string
  options: string[]
  session_id?: string
  urgency?: Urgency
  command?: string   // if present: render as "Permission needed" bash-style block
  style?: 'default' | 'list'
}

export interface AlertPayload {
  title: string
  body: string
  icon?: string
  urgency?: Urgency
}

export interface StatusPayload {
  label: string
  detail?: string
  icon?: string
  color?: StatusColor
}

export interface PromptPayload {
  title: string
  placeholder?: string
  multiline?: boolean
  urgency?: Urgency
}

export interface ChatPromptPayload {
  title: string
  context?: string
  placeholder?: string
  urgency?: Urgency
}

export interface ClaudeMessagePayload {
  text: string
  session_id?: string
}

export interface AgentSessionPayload {
  session_id: string
  task_id?: string
  project: string
  cwd: string
  last_message?: string
  is_working?: boolean
  agent_name?: string
  brand_color?: string
  placeholder?: string
  current_tool?: string       // e.g. 'Edit', 'Bash', 'Read', 'Glob', 'Agent'
  current_preview?: string    // tool-specific context: filename, command snippet
  permission_mode?: 'supervised' | 'full-auto'
  pending_confirmation?: {    // inline permission prompt from the script
    title: string
    options: string[]
  }
  tool_history?: Array<{ tool: string; preview: string; timestamp: string }>
  is_headless?: boolean
}

export interface StartSessionPayload {
  repos: Array<{ name: string; path: string }>
}

export interface InfoCardPayload {
  title: string
  pairs: Array<{ key: string; value: string }>
}

export interface IconCardPayload {
  title: string
  subtitle?: string
}

export interface TilePayload {
  label: string
  status_color?: string
  body?: string
  action_required?: boolean
}

export interface CountdownPayload {
  label: string
  time: string  // ISO 8601
}

export interface PickerPayload {
  title: string
  options: string[]
  selected?: string
}

export interface ListPayload {
  title?: string
  items: Array<{ id: string; label: string; subtitle?: string }>
  actions?: string[]
}

export interface DetailPayload {
  title: string
  body: string
  actions?: string[]
}

export interface FeedItemPayload {
  title: string
  body?: string
  timestamp?: string
  icon?: string
  color?: StatusColor
}

export interface QuickReplyPayload {
  title: string
  description?: string
  options: string[]
  allow_custom?: boolean
  urgency?: Urgency
}

// ---- Shared enums ----

export type Urgency = 'urgent' | 'warning' | 'info'
export type StatusColor = 'green' | 'blue' | 'orange' | 'red' | 'yellow'

// ---- Machine / Task ----

export interface Machine {
  machineID: string
  name: string
  platform: string
  lastHeartbeat: string
  status: 'idle' | 'busy'
}

export interface AskTask {
  taskID: string
  machineID: string
  scriptID: string
  scriptName: string
  scriptIcon?: string
  title: string
  status: 'working' | 'input-required' | 'completed' | 'failed' | 'cancelled'
  lastActivityAt: string
  messageCount: number
  artifactCount: number
}

export interface TaskMessage {
  messageID: string
  taskID: string
  role: 'user' | 'assistant'
  partsJSON: string  // JSON array of message parts
  timestamp: string
  sequenceNumber: number
}

export interface SessionEventPayload {
  event: 'started' | 'stopped'
  project: string
  cwd: string
  exit_code?: number
}

export interface ActivityFeedPayload {
  session_id: string
  project: string
  entries: Array<{ tool: string; preview: string; timestamp: string }>
}

export interface CompactSummaryPayload {
  session_id: string
  project: string
  trigger: string
  summary: string
}

export interface DiagnosticsPayload {
  version: string
  hooks: string[]
  hooks_ok: boolean
  socket_ok: boolean
  log_lines: string[]
}

// ---- SSE events ----

export type SSEEvent =
  | { type: 'block_added'; block: Block }
  | { type: 'block_updated'; block: Block }
  | { type: 'block_cleared'; blockID: string }
