/**
 * Manual-test walkthrough for `github` on the web surface.
 * Plan: manual-script-sweep · Case: github-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('github-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'github-web',
    scriptId: 'github',
    scriptName: 'Git Repos',
  })
})
