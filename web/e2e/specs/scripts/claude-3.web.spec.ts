/**
 * Manual-test walkthrough for `claude-3` on the web surface.
 * Plan: manual-script-sweep · Case: claude-3-web
 * Hard dep: terminal-manager (system script — must be enabled in vault)
 *
 * Claude 3 is a session supervisor — its detail screen shows a session list
 * and tapping a session opens a chat thread. The walkthrough adds an extra
 * "session list" step between populated state and the primary action.
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'
import { step } from '../../helpers/story'

test('claude-3-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'claude-3-web',
    scriptId: 'claude-3',
    scriptName: 'Claude 3',
    extra: async (page, story) => {
      await step(story, page, {
        title: 'Session list',
        description: 'The detail screen lists active and recent Claude Code sessions; verify the badges (tmux/in-process/headless) render correctly.',
      }, async () => { await page.waitForTimeout(500) })
    },
  })
})
