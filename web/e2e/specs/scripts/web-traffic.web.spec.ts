/**
 * Manual-test walkthrough for `web-traffic` on the web surface.
 * Plan: manual-script-sweep · Case: web-traffic-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('web-traffic-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'web-traffic-web',
    scriptId: 'web-traffic',
    scriptName: 'Web Traffic',
  })
})
