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
