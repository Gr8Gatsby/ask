import type { AskTask, TaskMessage } from '../../src/lib/types.js'

export const FIXTURE_TASKS: AskTask[] = [
  {
    taskID: 'task-001',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Refactor auth middleware',
    status: 'running',
    lastActivityAt: new Date(Date.now() - 2 * 60 * 1000).toISOString(),
    messageCount: 8,
    artifactCount: 2,
  },
  {
    taskID: 'task-002',
    machineID: 'mac-dev-1',
    scriptID: 'claude-3',
    scriptName: 'Claude Code',
    title: 'Add unit tests for UserService',
    status: 'completed',
    lastActivityAt: new Date(Date.now() - 45 * 60 * 1000).toISOString(),
    messageCount: 14,
    artifactCount: 4,
  },
]

export const FIXTURE_TASK_MESSAGES: Record<string, TaskMessage[]> = {
  'task-001': [
    {
      messageID: 'msg-001',
      taskID: 'task-001',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'Refactor the auth middleware to support OAuth2 token refresh.' }]),
      timestamp: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
      sequenceNumber: 0,
    },
    {
      messageID: 'msg-002',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "I'll start by reading the existing middleware. Let me look at `auth.ts`..." }]),
      timestamp: new Date(Date.now() - 9 * 60 * 1000).toISOString(),
      sequenceNumber: 1,
    },
    {
      messageID: 'msg-003',
      taskID: 'task-001',
      role: 'assistant',
      partsJSON: JSON.stringify([{ type: 'text', text: "Found **3 issues** with the current implementation:\n\n1. Token refresh doesn't handle 401 retries\n2. Missing exponential backoff\n3. No refresh token rotation\n\nRefactoring now..." }]),
      timestamp: new Date(Date.now() - 5 * 60 * 1000).toISOString(),
      sequenceNumber: 2,
    },
    {
      messageID: 'msg-004',
      taskID: 'task-001',
      role: 'user',
      partsJSON: JSON.stringify([{ type: 'text', text: 'Make sure to add tests too.' }]),
      timestamp: new Date(Date.now() - 3 * 60 * 1000).toISOString(),
      sequenceNumber: 3,
    },
  ],
}
