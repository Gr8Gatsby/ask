/**
 * Manual-test walkthrough for `codex-3` on the web surface.
 * Plan: manual-script-sweep · Case: codex-3-web
 * Hard deps: terminal-manager (system), tmux + codex CLI
 *
 * Codex 3 mirrors claude-3: a session supervisor with tmux transport. The
 * walkthrough adds a "session list" step between populated state and the
 * primary action.
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'
import { step } from '../../helpers/story'

test('codex-3-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'codex-3-web',
    scriptId: 'codex-3',
    scriptName: 'Codex 3',
    extra: async (page, story) => {
      await step(story, page, {
        title: 'Session list',
        description: 'The detail screen lists active and recent Codex sessions with tmux targets; verify the session pill renders.',
      }, async () => { await page.waitForTimeout(500) })
    },
  })
})
