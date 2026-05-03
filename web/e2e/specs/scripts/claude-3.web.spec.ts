/**
 * Web case · claude-3
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('claude-3-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'claude-3-web')
})
