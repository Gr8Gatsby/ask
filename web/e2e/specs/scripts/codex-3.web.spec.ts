/**
 * Web case · codex-3
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('codex-3-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'codex-3-web')
})
