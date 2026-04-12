import type { Block } from '../lib/types'

function fixture(blockType: Block['blockType'], payload: unknown, overrides: Partial<Block> = {}): Block {
  return {
    blockID: `catalog-${blockType}`,
    machineID: 'mock',
    scriptID: 'catalog',
    scriptName: 'Catalog',
    blockType,
    payload: JSON.stringify(payload),
    createdAt: new Date().toISOString(),
    scriptType: 'tile',
    requiresResponse: 0,
    showsInInbox: 0,
    ...overrides,
  }
}

export const CATALOG_FIXTURES: { label: string; block: Block }[] = [
  {
    label: 'Confirmation',
    block: fixture('confirmation', {
      title: 'Deploy to production?',
      body: 'This will push v2.4.1 to all production servers.',
      options: ['Deploy', 'Cancel'],
      urgency: 'warning',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Confirmation (3+ options)',
    block: fixture('confirmation', {
      title: 'How should I handle the conflict?',
      body: 'There is a merge conflict in auth.ts.',
      options: ['Rebase', 'Merge', 'Stash & Abort'],
      urgency: 'urgent',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Alert',
    block: fixture('alert', {
      title: 'Build Failed',
      body: 'Unit tests failed on step 3 of the CI pipeline.',
      urgency: 'urgent',
    }),
  },
  {
    label: 'Status',
    block: fixture('status', {
      label: 'Deployment Running',
      detail: 'Step 3 of 7 — uploading assets to S3',
      color: 'blue',
    }),
  },
  {
    label: 'Prompt',
    block: fixture('prompt', {
      title: 'Commit message',
      placeholder: 'Fix login timeout bug',
      multiline: false,
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Prompt (multiline)',
    block: fixture('prompt', {
      title: 'Release notes',
      placeholder: 'Describe what changed...',
      multiline: true,
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Chat Prompt',
    block: fixture('chat_prompt', {
      title: 'Reply to Claude',
      context: "I found **3 failing tests**. Should I attempt auto-fixes or open a ticket for each?",
      placeholder: 'Reply to Claude...',
      urgency: 'warning',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Claude Message',
    block: fixture('claude_message', {
      text: "## Analysis complete\n\nI've reviewed the codebase and found **3 issues**:\n\n- Auth token not refreshed\n- Missing error handling in `fetchUser()`\n- Stale cache on logout\n\nAll fixes are committed.",
    }),
  },
  {
    label: 'Agent Session',
    block: fixture('agent_session', {
      session_id: 'session-catalog',
      project: 'code/ask [a3f9]',
      cwd: '/Users/kevin/Documents/code/ask',
      last_message: "I've updated the auth middleware. All tests pass.",
      is_working: false,
      agent_name: 'Claude Code',
      brand_color: '#74AA9C',
      placeholder: 'Reply to Claude...',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Agent Session (working)',
    block: fixture('agent_session', {
      session_id: 'session-catalog-working',
      project: 'code/api-server [b7c2]',
      cwd: '/Users/kevin/Documents/code/api-server',
      is_working: true,
      agent_name: 'Claude Code',
      brand_color: '#74AA9C',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Start Session',
    block: fixture('start_session', {
      repos: [
        { name: 'code/ask', path: '/Users/kevin/Documents/code/ask' },
        { name: 'code/api-server', path: '/Users/kevin/Documents/code/api-server' },
      ],
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Info Card',
    block: fixture('info_card', {
      title: 'Pull Request #482',
      pairs: [
        { key: 'Branch', value: 'feature/auth' },
        { key: 'Author', value: 'kevin' },
        { key: 'Status', value: 'Ready for review' },
        { key: 'Changed', value: '14 files' },
      ],
    }),
  },
  {
    label: 'Countdown',
    block: fixture('countdown', {
      label: 'Code Freeze',
      time: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
    }),
  },
  {
    label: 'Picker',
    block: fixture('picker', {
      title: 'Target environment',
      options: ['staging', 'production', 'canary'],
      selected: 'staging',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'List',
    block: fixture('list', {
      title: 'Open Pull Requests',
      items: [
        { id: 'pr-482', label: '#482 feature/auth', subtitle: 'Ready for review' },
        { id: 'pr-479', label: '#479 fix/timeout', subtitle: '2 reviewers approved' },
        { id: 'pr-471', label: '#471 chore/deps', subtitle: 'Needs rebase' },
      ],
      actions: ['Refresh'],
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Detail',
    block: fixture('detail', {
      title: 'PR #482 — feature/auth',
      body: 'Adds OAuth2 token refresh logic to the auth middleware.\nFixes the 401 loop seen in staging after token expiry.\n\nTests: 42 added, 0 failing.\nCoverage: 87% (+3%).',
      actions: ['Merge', 'Close PR'],
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Feed Item',
    block: fixture('feed_item', {
      title: '3 packages updated',
      body: 'openssl 3.4.0, git 2.47.1, node 22.12.0',
      timestamp: new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString(),
      color: 'green',
    }),
  },
  {
    label: 'Quick Reply',
    block: fixture('quick_reply', {
      title: 'Update 3 outdated packages?',
      description: 'openssl, git, node — total ~240MB',
      options: ['Update All', 'Skip'],
      urgency: 'warning',
    }, { requiresResponse: 1 }),
  },
  {
    label: 'Quick Reply (custom)',
    block: fixture('quick_reply', {
      title: 'Delete 47 migration files?',
      description: 'This cannot be undone.',
      options: ['Yes', 'No'],
      allow_custom: true,
      urgency: 'urgent',
    }, { requiresResponse: 1 }),
  },
]
