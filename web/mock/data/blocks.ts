import type { Block } from '../../src/lib/types.js'

function block(partial: Omit<Block, 'machineID' | 'createdAt' | 'requiresResponse' | 'showsInInbox'> & {
  requiresResponse?: number
  showsInInbox?: number
}): Block {
  return {
    machineID: 'mac-dev-1',
    createdAt: new Date().toISOString(),
    requiresResponse: 0,
    showsInInbox: 0,
    ...partial,
  }
}

export const FIXTURE_BLOCKS: Block[] = [
  // ---- Claude Code script ----
  block({
    blockID: 'claudecode-tile',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'tile',
    scriptType: 'tile',
    payload: JSON.stringify({ label: 'Working', status_color: 'blue', body: 'Editing SessionChatScreen.tsx…' }),
  }),

  // session_event: started
  block({
    blockID: 'claudecode-event-start',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'session_event',
    scriptType: 'tile',
    payload: JSON.stringify({
      event: 'started',
      project: 'code/ask [a3f9]',
      cwd: '/Users/kevin/Documents/code/ask',
    }),
  }),

  // activity_feed: recent tool calls
  block({
    blockID: 'claudecode-activity',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'activity_feed',
    scriptType: 'tile',
    payload: JSON.stringify({
      session_id: 'session-a3f91c2b',
      project: 'code/ask [a3f9]',
      entries: [
        { tool: 'Read',  preview: 'web/src/screens/SessionChatScreen.tsx', timestamp: new Date(Date.now() - 4 * 60_000).toISOString() },
        { tool: 'Edit',  preview: 'web/src/screens/SessionChatScreen.tsx', timestamp: new Date(Date.now() - 3 * 60_000).toISOString() },
        { tool: 'Bash',  preview: 'npm run lint',                          timestamp: new Date(Date.now() - 2 * 60_000).toISOString() },
        { tool: 'Bash',  preview: 'git add -p',                            timestamp: new Date(Date.now() - 1 * 60_000).toISOString() },
      ],
    }),
  }),

  // agent_session — working, with currentTool + pendingConfirmation
  block({
    blockID: 'claudecode-session-a3f91c2b',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'agent_session',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 0,
    payload: JSON.stringify({
      session_id: 'session-a3f91c2b',
      task_id: 'task-001',
      project: 'code/ask [a3f9]',
      cwd: '/Users/kevin/Documents/code/ask',
      last_message: "I've refactored the auth middleware. All 42 tests pass. Ready for review.",
      is_working: true,
      current_tool: 'Bash',
      current_preview: 'git commit -m "web: rebuild SessionChatScreen"',
      agent_name: 'Claude Code',
      brand_color: '#74AA9C',
      placeholder: 'Reply to Claude…',
      permission_mode: 'supervised',
      tool_history: [
        { tool: 'Read',  preview: 'web/src/screens/SessionChatScreen.tsx', timestamp: new Date(Date.now() - 4 * 60_000).toISOString() },
        { tool: 'Edit',  preview: 'web/src/screens/SessionChatScreen.tsx', timestamp: new Date(Date.now() - 3 * 60_000).toISOString() },
        { tool: 'Bash',  preview: 'npm run lint',                          timestamp: new Date(Date.now() - 2 * 60_000).toISOString() },
        { tool: 'Bash',  preview: 'git add -p',                            timestamp: new Date(Date.now() - 1 * 60_000).toISOString() },
      ],
      pending_confirmation: {
        title: 'Run linter before committing?',
        options: ['Fix & Commit', 'Skip Lint', 'Cancel'],
      },
    }),
  }),

  // Bash permission block — surfaces on home screen as alert chip
  block({
    blockID: 'claudecode-bash-permission',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'confirmation',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 1,
    payload: JSON.stringify({
      title: 'Permission needed',
      body: 'Claude Code wants to run a shell command.',
      command: 'rsync --delete /Users/kevin/Documents/code/ask/ask/scripts/\n  ~/.ask/scripts/claude-3/',
      options: ['Allow', 'Deny'],
      session_id: 'session-a3f91c2b',
      urgency: 'urgent',
    }),
  }),

  block({
    blockID: 'claudecode-start-session',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'start_session',
    scriptType: 'tile',
    requiresResponse: 1,
    payload: JSON.stringify({
      repos: [
        { name: 'code/ask', path: '/Users/kevin/Documents/code/ask' },
        { name: 'code/api-server', path: '/Users/kevin/Documents/code/api-server' },
      ],
    }),
  }),

  // ---- Brew Monitor script ----
  block({
    blockID: 'brew-tile',
    scriptID: 'brew-monitor',
    scriptName: 'Brew Monitor',
    blockType: 'tile',
    scriptType: 'tile',
    payload: JSON.stringify({ label: '3 updates available', status_color: 'orange', action_required: true }),
  }),
  block({
    blockID: 'brew-alert',
    scriptID: 'brew-monitor',
    scriptName: 'Brew Monitor',
    blockType: 'alert',
    scriptType: 'tile',
    payload: JSON.stringify({
      title: 'Security Update Available',
      body: 'openssl has a critical security patch. Run `brew upgrade openssl` to update.',
      urgency: 'urgent',
    }),
  }),
  block({
    blockID: 'brew-countdown',
    scriptID: 'brew-monitor',
    scriptName: 'Brew Monitor',
    blockType: 'countdown',
    scriptType: 'tile',
    payload: JSON.stringify({
      label: 'Auto-update in',
      time: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
    }),
  }),
  block({
    blockID: 'brew-quick-reply',
    scriptID: 'brew-monitor',
    scriptName: 'Brew Monitor',
    blockType: 'quick_reply',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 1,
    payload: JSON.stringify({
      title: 'Update 3 outdated packages?',
      description: 'openssl, git, node — total ~240MB',
      options: ['Update All', 'Skip'],
      allow_custom: false,
      urgency: 'warning',
    }),
  }),

  // ---- Claude Code: header blocks ----
  block({
    blockID: 'claude-message-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'claude_message',
    scriptType: 'tile',
    payload: JSON.stringify({
      text: "## Analysis complete\n\nI've reviewed the codebase and found **3 issues**:\n\n- Auth token not refreshed on 401\n- Missing error handling in `fetchUser()`\n- Stale cache on logout\n\nAll fixes are committed to `feature/auth-refresh`.",
      session_id: 'session-a3f91c2b',
    }),
  }),
  block({
    blockID: 'chat-prompt-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'chat_prompt',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 1,
    payload: JSON.stringify({
      title: 'Reply to Claude',
      context: "I found **3 failing tests**. Should I attempt auto-fixes or open a ticket for each?",
      placeholder: 'Reply to Claude…',
      urgency: 'warning',
    }),
  }),
  block({
    blockID: 'prompt-commit-msg',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'prompt',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 1,
    payload: JSON.stringify({
      title: 'Commit message',
      placeholder: 'Fix login timeout bug',
      multiline: false,
      urgency: 'info',
    }),
  }),
]
