/**
 * Manual-test walkthrough for `gdocs-history` on the web surface.
 * Plan: manual-script-sweep · Case: gdocs-history-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('gdocs-history-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'gdocs-history-web',
    scriptId: 'gdocs-history',
    scriptName: 'Google Docs History',
  })
})
