/**
 * Manual-test walkthrough for `ollama` on the web surface.
 * Plan: manual-script-sweep · Case: ollama-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('ollama-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'ollama-web',
    scriptId: 'ollama',
    scriptName: 'Ollama',
  })
})
