import type { AskTask, TaskMessage } from '../../src/lib/types.js'

export const FIXTURE_TASKS: AskTask[] = [
  {
    taskID: 'task-001',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Rebuild SessionChatScreen with chat history',
    status: 'input-required',
    lastActivityAt: new Date(Date.now() - 1 * 60 * 1000).toISOString(),
    messageCount: 6,
    artifactCount: 2,
  },
  {
    taskID: 'task-004',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Agent gap remediation — web dev UI',
    status: 'working',
    lastActivityAt: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
    messageCount: 12,
    artifactCount: 6,
  },
  {
    taskID: 'task-002',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Fix deploy-scripts hook — rsync blocked from iPhone',
    status: 'completed',
    lastActivityAt: new Date(Date.now() - 45 * 60 * 1000).toISOString(),
    messageCount: 8,
    artifactCount: 2,
  },
  {
    taskID: 'task-003',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Screenshot UI and generate design notes',
    status: 'completed',
    lastActivityAt: new Date(Date.now() - 20 * 60 * 1000).toISOString(),
    messageCount: 5,
    artifactCount: 1,
  },
]

export const FIXTURE_TASK_MESSAGES: Record<string, TaskMessage[]> = {
  'task-001': [
    {
      messageID: 'msg-001',
      taskID: 'task-001',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'The SessionChatScreen needs a full rebuild — it should show chat history, the current tool being run, an inline pending confirmation bar, and a Stop button.' }]),
      timestamp: new Date(Date.now() - 15 * 60 * 1000).toISOString(),
      sequenceNumber: 0,
    },
    {
      messageID: 'msg-002',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "I'll rebuild SessionChatScreen to match the iOS SessionChatView:\n\n1. Load chat history from `getTaskMessages(task_id)` on mount\n2. Show `current_tool` + `current_preview` as a status line while working\n3. Render `pending_confirmation` from the session payload as a button bar above the compose input\n4. Add **Stop** (`__close_session__`) and **permission mode toggle** (`__permissions__`) actions\n\nReading the current file first…" }]),
      timestamp: new Date(Date.now() - 14 * 60 * 1000).toISOString(),
      sequenceNumber: 1,
    },
    {
      messageID: 'msg-003',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([
        { type: 'tool_use', id: 'tu_read', name: 'Read', input: { file_path: 'web/src/screens/SessionChatScreen.tsx' } },
      ]),
      timestamp: new Date(Date.now() - 13 * 60 * 1000).toISOString(),
      sequenceNumber: 2,
    },
    {
      messageID: 'msg-004',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "Done. Key changes:\n\n- `getTaskMessages(task_id)` loads history on mount; messages render as chat bubbles\n- Working state shows `current_tool` icon + `current_preview` filename above the bounce dots\n- `pending_confirmation` from payload renders as an orange button bar above the compose bar (not a separate block lookup)\n- Nav bar gains **Stop** (red) and **Feed** link; permission mode shows as a badge\n- Stop sends `__close_session__`, permission toggle sends `__permissions__`" }]),
      timestamp: new Date(Date.now() - 2 * 60 * 1000).toISOString(),
      sequenceNumber: 3,
    },
    {
      messageID: 'msg-005',
      taskID: 'task-001',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'Run linter before committing?' }]),
      timestamp: new Date(Date.now() - 1 * 60 * 1000).toISOString(),
      sequenceNumber: 4,
    },
  ],

  'task-004': [
    {
      messageID: 'msg-401',
      taskID: 'task-004',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'Build a browser-based dev tool that renders Ask blocks with live reload.' }]),
      timestamp: new Date(Date.now() - 40 * 60 * 1000).toISOString(),
      sequenceNumber: 0,
    },
    {
      messageID: 'msg-402',
      taskID: 'task-004',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "Set up Vite + React + TypeScript + Tailwind with MockAskMac on port 4242. SSE for live block updates, proxy via Vite config.\n\nImplemented all block renderers and the 4 high-impact functional fixes:\n- ActionQueueCard per script group\n- ScriptDetailScreen two-section layout\n- SessionChatScreen push navigation\n- Confirmation blocks grouped under their session" }]),
      timestamp: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
      sequenceNumber: 1,
    },
  ],

  'task-002': [
    {
      messageID: 'msg-201',
      taskID: 'task-002',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'The deploy-scripts button (⊞) in AskMac Actions tab is not working. The rsync is being denied from the iPhone.' }]),
      timestamp: new Date(Date.now() - 90 * 60 * 1000).toISOString(),
      sequenceNumber: 0,
    },
    {
      messageID: 'msg-202',
      taskID: 'task-002',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "It looks like the Bash commands are being denied from the iPhone. Type this in your terminal to run it directly:\n\n```sh\nrsync --delete /Users/kevin/Documents/code/ask/ask/scripts/ ~/.ask/scripts/claude-3/\n```\n\n**Root cause:** `discover_active_processes()` created a pid-XXXXX register for any Claude process it couldn't match. Those transients were then excluded from TTY liveness eviction in `refresh_sessions()` (because `session.is_transient` is false), so they accumulated and never died.\n\n**Three-part fix (v0.0.2):**\n\n1. **Removed transient creation** — unknown processes are now just logged and skipped. Sessions that started before the daemon self-register when their next hook event fires.\n2. **Removed transient eviction exemption** — `_refresh_sessions()` now evicts any transient (registered or not) whose TTY is dead, cleaning up any lingering transients.\n3. **Added cleanup in `_handle_session_open()`** — when a proper hook session starts, any transient with the same TTY or CWD is explicitly cleared and removed before the real session is registered." }]),
      timestamp: new Date(Date.now() - 80 * 60 * 1000).toISOString(),
      sequenceNumber: 1,
    },
    {
      messageID: 'msg-203',
      taskID: 'task-002',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "**Session stopped**\n\nClaude Code exited in `ask`." }]),
      timestamp: new Date(Date.now() - 45 * 60 * 1000).toISOString(),
      sequenceNumber: 2,
    },
  ],

  'task-003': [
    {
      messageID: 'msg-301',
      taskID: 'task-003',
      role: 'user',
      partsJSON: JSON.stringify([
        { type: 'text', text: 'Take a screenshot of the web dev UI and write up design notes.' },
        {
          type: 'document',
          source: {
            type: 'base64',
            media_type: 'text/plain',
            data: btoa('Design brief: focus on parity with iOS app dark palette'),
            filename: 'design-brief.txt',
          },
        },
      ]),
      timestamp: new Date(Date.now() - 25 * 60 * 1000).toISOString(),
      sequenceNumber: 0,
    },
    {
      messageID: 'msg-302',
      taskID: 'task-003',
      role: 'assistant',
      partsJSON: JSON.stringify([
        {
          type: 'tool_use',
          id: 'tu_01',
          name: 'mcp__playwright__browser_take_screenshot',
          input: { type: 'png' },
        },
      ]),
      timestamp: new Date(Date.now() - 24 * 60 * 1000).toISOString(),
      sequenceNumber: 1,
    },
    {
      messageID: 'msg-303',
      taskID: 'task-003',
      role: 'user',
      partsJSON: JSON.stringify([
        {
          type: 'tool_result',
          tool_use_id: 'tu_01',
          content: 'Screenshot saved to .playwright-mcp/page-2026-04-12.png',
        },
        {
          type: 'image',
          source: {
            type: 'url',
            url: 'https://placehold.co/390x844/1c1c1e/8e8e93?text=Web+Dev+UI',
          },
        },
      ]),
      timestamp: new Date(Date.now() - 23 * 60 * 1000).toISOString(),
      sequenceNumber: 2,
    },
    {
      messageID: 'msg-304',
      taskID: 'task-003',
      role: 'assistant',
      partsJSON: JSON.stringify([
        {
          type: 'text',
          text: "## Design notes\n\n**Palette** — matches iOS dark system colors (`#1c1c1e` bg, `#2c2c2e` card). Good.\n\n**Typography** — SF Pro replaced by system font stack; rendering is close but line-height is slightly tighter on web.\n\n**Gaps vs iOS:**\n- Action cards use `bg-ask-card` but iOS uses a blur effect on the card background\n- Session row chevron (`›`) should be `chevron.right` SF Symbol at 12pt, not a text character\n- Countdown block timer font should be monospaced digits\n\n**Recommendation:** Add `tabular-nums` to the countdown and use `backdrop-blur` on cards.",
        },
      ]),
      timestamp: new Date(Date.now() - 20 * 60 * 1000).toISOString(),
      sequenceNumber: 3,
    },
  ],
}
