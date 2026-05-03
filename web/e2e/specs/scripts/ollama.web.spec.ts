/**
 * Web case · ollama
 * Steps are declared in web/review-plans/manual-script-sweep.json.
 */
import { test } from '@playwright/test'
import { runWebCase } from './_walkthrough'

test('ollama-web', async ({ page }, testInfo) => {
  await runWebCase(page, testInfo, 'ollama-web')
})
