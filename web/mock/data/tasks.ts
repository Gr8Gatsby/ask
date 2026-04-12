import type { AskTask, TaskMessage } from '../../src/lib/types.js'

export const FIXTURE_TASKS: AskTask[] = [
  {
    taskID: 'task-001',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Agent gap remediation — web dev UI',
    status: 'running',
    lastActivityAt: new Date(Date.now() - 2 * 60 * 1000).toISOString(),
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
]

export const FIXTURE_TASK_MESSAGES: Record<string, TaskMessage[]> = {
  'task-001': [
    {
      messageID: 'msg-001',
      taskID: 'task-001',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'Build a browser-based dev tool that renders Ask blocks with live reload, so we can test UI changes without rebuilding the native iOS app.' }]),
      timestamp: new Date(Date.now() - 40 * 60 * 1000).toISOString(),
      sequenceNumber: 0,
    },
    {
      messageID: 'msg-002',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "I'll set up a Vite + React + TypeScript + Tailwind stack with MockAskMac as the data source. The mock server will run on port 4242 and serve blocks over SSE so the UI stays live without CloudKit.\n\nStarting with the project scaffold..." }]),
      timestamp: new Date(Date.now() - 39 * 60 * 1000).toISOString(),
      sequenceNumber: 1,
    },
    {
      messageID: 'msg-003',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "Created:\n- `web/` — Vite app with iOS dark palette\n- `web/mock/server.ts` — MockAskMac (port 4242, SSE, respond endpoint)\n- `web/src/lib/useBlocks.ts` — live block state via SSE\n- All 16 block renderers\n\nRunning `npm run dev` starts both the mock server and Vite together." }]),
      timestamp: new Date(Date.now() - 35 * 60 * 1000).toISOString(),
      sequenceNumber: 2,
    },
    {
      messageID: 'msg-004',
      taskID: 'task-001',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'The website seems quite a bit different than the iOS app functionally. Functional differences is more important — go for the high impact ones.' }]),
      timestamp: new Date(Date.now() - 20 * 60 * 1000).toISOString(),
      sequenceNumber: 3,
    },
    {
      messageID: 'msg-005',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "Identified the 4 highest-impact gaps:\n\n1. **Needs-response queue** — was showing per-block chips instead of per-script ActionQueueCards\n2. **Script detail layout** — missing two-section split (header blocks + Sessions list)\n3. **Session push** — no SessionChatScreen; tapping a session went nowhere\n4. **Confirmation grouping** — confirmations linked to a session weren't shown under their session row\n\nImplementing all four now." }]),
      timestamp: new Date(Date.now() - 18 * 60 * 1000).toISOString(),
      sequenceNumber: 4,
    },
    {
      messageID: 'msg-006',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "All four fixes committed to `feature/agent-gap-remediation`.\n\n- `ActionQueueCard.tsx` — per-script-group card with inline quick_reply\n- `HomeScreen.tsx` — Needs Response + Recent sections\n- `ScriptDetailScreen.tsx` — header blocks + Sessions section with linked confirmations\n- `SessionChatScreen.tsx` — pushed on session tap; shows last_message, confirmations, reply input\n- `App.tsx` — added `/script/:id/session/:sid` route" }]),
      timestamp: new Date(Date.now() - 2 * 60 * 1000).toISOString(),
      sequenceNumber: 5,
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
}
