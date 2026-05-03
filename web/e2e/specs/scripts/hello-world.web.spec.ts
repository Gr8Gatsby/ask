/**
 * Manual-test walkthrough for the `hello-world` script on the web surface.
 *
 * Belongs to plan: manual-script-sweep
 * Case id:       hello-world-web
 *
 * Walks the eight common steps from §7.1 of docs/specs/manual-script-test-plan.md
 * (cold open, tile entry, tap into detail, empty state, populated state,
 * primary action, error/refused, back-out). Each step is captured as a
 * screenshot + HTML snapshot via the story recorder so the dashboard can
 * pin issues with location and "Copy step context" hand-off.
 *
 * Phase 1 caveats:
 *   - Vault isolation is not yet automated; tester must ensure other
 *     scripts are disabled before kicking off the run.
 *   - Hello-world has no real "primary action" or "error state" — for those
 *     steps we capture the home screen and the settings screen as
 *     informative placeholders so the case shape stays uniform.
 */
import { test } from '@playwright/test'
import { newStory, step } from '../../helpers/story'

test('hello-world-web', async ({ page }, testInfo) => {
  const story = newStory(testInfo, {
    caseId: 'hello-world-web',
    title: 'Hello World · Web walkthrough',
    description: 'Cold open through back-out for the hello-world script on the iPhone webview.',
  })

  await step(story, page, {
    title: 'Cold open',
    description: 'Open the home feed at /home with no other interaction; expect the script list to render and the hello-world tile to be present.',
  }, '/home')

  await step(story, page, {
    title: 'Tile / feed entry',
    description: 'The hello-world tile renders with its icon and name in the home feed.',
  }, async () => {
    await page.waitForTimeout(250)
  })

  await step(story, page, {
    title: 'Tap into detail',
    description: 'Navigate to the script detail screen for hello-world.',
  }, '/script/hello-world')

  await step(story, page, {
    title: 'Empty state',
    description: 'Detail screen with no recent runs / no recorded blocks — verifies the empty layout.',
  }, async () => {
    await page.waitForTimeout(250)
  })

  await step(story, page, {
    title: 'Populated state',
    description: 'Same screen after a brief settle — captures whatever blocks the script publishes by default.',
  }, async () => {
    await page.waitForTimeout(800)
  })

  await step(story, page, {
    title: 'Primary action',
    description: 'Hello-world has no interactive primary action; capture the settings screen as a representative cross-link the user might tap from detail.',
  }, '/settings')

  await step(story, page, {
    title: 'Error / refused state',
    description: 'Hello-world declares no permissions; capture the tasks list as the closest analog of a "nothing to act on" surface.',
  }, '/tasks')

  await step(story, page, {
    title: 'Back-out',
    description: 'Return to the home feed; verify the tile state survives navigation.',
  }, '/home')
})
