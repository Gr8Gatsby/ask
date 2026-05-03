/**
 * Manual-test walkthrough for `terminal-snapshot` on the web surface.
 * Plan: manual-script-sweep · Case: terminal-snapshot-web
 * Hard dep: terminal-manager (system script — must be enabled in vault)
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('terminal-snapshot-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'terminal-snapshot-web',
    scriptId: 'terminal-snapshot',
    scriptName: 'Terminal Snapshot',
  })
})
