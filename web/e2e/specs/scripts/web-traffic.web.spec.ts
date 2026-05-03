/**
 * Web case · web-traffic
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('web-traffic-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'web-traffic-web')
})
