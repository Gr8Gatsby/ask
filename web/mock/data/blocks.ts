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
    payload: JSON.stringify({ label: 'Running', status_color: 'blue', body: 'Working on agent gap remediation...' }),
  }),
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
      is_working: false,
      agent_name: 'Claude Code',
      brand_color: '#74AA9C',
      placeholder: 'Reply to Claude...',
    }),
  }),
  block({
    blockID: 'claudecode-confirmation-lint',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'confirmation',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 1,
    payload: JSON.stringify({
      title: 'Run linter before committing?',
      body: 'Found 3 auto-fixable lint errors in auth.ts.',
      options: ['Fix & Commit', 'Skip Lint', 'Cancel'],
      session_id: 'session-a3f91c2b',
      urgency: 'warning',
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
      icon: 'exclamationmark.shield.fill',
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
      placeholder: 'Reply to Claude...',
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

  // ---- Feed items ----
  block({
    blockID: 'feed-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    blockType: 'feed_item',
    scriptType: 'feed',
    payload: JSON.stringify({
      title: 'Session started',
      body: 'Claude Code is working on ask/agent gap remediation',
      timestamp: new Date(Date.now() - 15 * 60 * 1000).toISOString(),
      color: 'blue',
    }),
  }),
  block({
    blockID: 'feed-2',
    scriptID: 'brew-monitor',
    scriptName: 'Brew Monitor',
    blockType: 'feed_item',
    scriptType: 'feed',
    payload: JSON.stringify({
      title: '3 packages updated',
      body: 'openssl 3.4.0, git 2.47.1, node 22.12.0',
      timestamp: new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString(),
      color: 'green',
    }),
  }),
]
