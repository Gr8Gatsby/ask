/**
 * Web case · hello-world
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('hello-world-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'hello-world-web')
})
