/**
 * Manual-test walkthrough for `task-demo` on the web surface.
 * Plan: manual-script-sweep · Case: task-demo-web
 */
import { test } from '@playwright/test'
import { runWebWalkthrough } from './_walkthrough'

test('task-demo-web', async ({ page }, testInfo) => {
  await runWebWalkthrough(page, testInfo, {
    caseId: 'task-demo-web',
    scriptId: 'task-demo',
    scriptName: 'Task Demo',
  })
})
