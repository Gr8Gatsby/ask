/**
 * Web case · github
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('github-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'github-web')
})
