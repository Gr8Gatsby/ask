/**
 * Manual-test walkthrough for `hello-world` on the web surface.
 * Plan: manual-script-sweep · Case: hello-world-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('hello-world-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'hello-world-web',
    scriptId: 'hello-world',
    scriptName: 'Hello World',
  })
})
