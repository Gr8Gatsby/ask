/**
 * Shared 8-step walkthrough for a script's web surface. Each per-script spec
 * imports this and supplies the script id + case id. Customisations (e.g.
 * additional script-specific steps) are appended by the caller via `extra`.
 *
 * The eight common steps follow §7.1 of docs/specs/manual-script-test-plan.md.
 */
import type { Page, TestInfo } from '@playwright/test'
import { newStory, step } from '../../helpers/story'

export interface WalkthroughOpts {
  caseId: string
  scriptId: string
  scriptName: string
  /** Optional script-specific steps to run between "Populated state" and "Back-out". */
  extra?: (page: Page, story: ReturnType<typeof newStory>) => Promise<void>
}

export async function runWebWalkthrough(
  page: Page,
  testInfo: TestInfo,
  opts: WalkthroughOpts,
): Promise<void> {
  const story = newStory(testInfo, {
    caseId: opts.caseId,
    title: `${opts.scriptName} · Web walkthrough`,
    description: `Cold open through back-out for the ${opts.scriptId} script on the iPhone webview.`,
  })

  await step(story, page, {
    title: 'Cold open',
    description: 'Open the home feed at /home with no other interaction; expect the script list to render.',
  }, '/home')

  await step(story, page, {
    title: 'Tile / feed entry',
    description: `The ${opts.scriptId} tile or feed entry renders with its icon and name in the home feed.`,
  }, async () => { await page.waitForTimeout(300) })

  await step(story, page, {
    title: 'Tap into detail',
    description: `Navigate to /script/${opts.scriptId} — the script's primary surface.`,
  }, `/script/${opts.scriptId}`)

  await step(story, page, {
    title: 'Empty state',
    description: 'Detail screen on first paint — what the user sees before data arrives.',
  }, async () => { await page.waitForTimeout(300) })

  await step(story, page, {
    title: 'Populated state',
    description: 'Same screen after a brief settle — captures whatever blocks the script publishes.',
  }, async () => { await page.waitForTimeout(900) })

  if (opts.extra) await opts.extra(page, story)

  await step(story, page, {
    title: 'Primary action',
    description: `Visit /tasks to confirm any tasks emitted by ${opts.scriptId} are in the feed.`,
  }, '/tasks')

  await step(story, page, {
    title: 'Error / refused state',
    description: `Visit /settings to confirm ${opts.scriptId} permissions and toggles render correctly.`,
  }, '/settings')

  await step(story, page, {
    title: 'Back-out',
    description: 'Return to the home feed; verify the tile state survives navigation.',
  }, '/home')
}
