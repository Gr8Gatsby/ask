/**
 * Web case · gdocs-history
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('gdocs-history-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'gdocs-history-web')
})
