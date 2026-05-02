/**
 * Step-by-step "story" recorder for e2e specs.
 *
 *   import { newStory, step } from './helpers/story'
 *   const story = newStory(testInfo)
 *   await step(story, page, 'Open home', '/')
 *   await step(story, page, 'Click first session', async () => {
 *     await page.locator('...').click()
 *   })
 *
 * Each call:
 *   - performs the action (navigate to a path / run a function / no-op for label-only)
 *   - takes a screenshot named NN-<slug>.png
 *   - appends an entry to story.json
 *
 * Output lives in:
 *   e2e/screenshots/__story/<test-slug>/
 *
 * The review dashboard freezes that directory into the run's frozen
 * storage and renders it as a vertical timeline with per-step feedback.
 */
import type { Page, TestInfo } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..', 'screenshots', '__story')

export interface StoryStep {
  idx: number
  name: string
  file: string
  at: number
  durationMs: number
}

export interface Story {
  dir: string
  testTitle: string
  startedAt: number
  steps: StoryStep[]
}

function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)
}

export function newStory(testInfo: TestInfo): Story {
  const testSlug = slug(testInfo.titlePath.join(' '))
  const dir = path.join(ROOT, testSlug)
  // Reset on every run so old steps don't leak in
  fs.rmSync(dir, { recursive: true, force: true })
  fs.mkdirSync(dir, { recursive: true })
  return { dir, testTitle: testInfo.titlePath.join(' › '), startedAt: Date.now(), steps: [] }
}

type StepAction = string | (() => Promise<void> | void) | undefined

export async function step(story: Story, page: Page, name: string, action?: StepAction): Promise<void> {
  const t0 = Date.now()
  if (typeof action === 'string') {
    await page.goto(action)
  } else if (typeof action === 'function') {
    await action()
  }
  // Tiny settle so Playwright's auto-screenshot catches post-action state.
  await page.waitForTimeout(150)

  const idx = story.steps.length
  const file = `${String(idx).padStart(2, '0')}-${slug(name)}.png`
  await page.screenshot({ path: path.join(story.dir, file), fullPage: false })
  story.steps.push({
    idx,
    name,
    file,
    at: Date.now(),
    durationMs: Date.now() - t0,
  })
  fs.writeFileSync(
    path.join(story.dir, 'story.json'),
    JSON.stringify({ testTitle: story.testTitle, startedAt: story.startedAt, steps: story.steps }, null, 2),
  )
}
