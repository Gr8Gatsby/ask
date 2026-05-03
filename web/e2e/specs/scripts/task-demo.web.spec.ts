/**
 * Web case · task-demo
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('task-demo-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'task-demo-web')
})
