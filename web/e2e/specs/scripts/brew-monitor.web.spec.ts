/**
 * Manual-test walkthrough for `brew-monitor` on the web surface.
 * Plan: manual-script-sweep · Case: brew-monitor-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('brew-monitor-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'brew-monitor-web',
    scriptId: 'brew-monitor',
    scriptName: 'Homebrew',
  })
})
