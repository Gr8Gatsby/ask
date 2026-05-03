/**
 * Web case · terminal-snapshot
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('terminal-snapshot-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'terminal-snapshot-web')
})
