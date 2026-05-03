/**
 * Web case · brew-monitor
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('brew-monitor-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'brew-monitor-web')
})
