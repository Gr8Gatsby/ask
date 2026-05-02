/**
 * Step-by-step "story" recorder for e2e specs.
 *
 *   import { newStory, step } from './helpers/story'
 *
 *   const story = newStory(testInfo, {
 *     title: 'Sending a new message to a live Codex agent',
 *     description: 'Types a probe into the chat, presses Enter, and ' +
 *       'confirms both the daemon log and the tmux pane received it.',
 *   })
 *
 *   await step(story, page, {
 *     title: 'Open the Codex chat',
 *     description: 'Expect the conversation history with prior turns ' +
 *       'and a reply input pinned at the bottom.',
 *   }, '/script/codex-3/session/<id>')
 *
 * For brevity, a plain string step also works (title only):
 *   await step(story, page, 'Click the reply input', () => input.click())
 *
 * Each step performs the action (navigate / function / no-op for label-only),
 * takes a screenshot, and appends to story.json. The review dashboard
 * renders this as a vertical timeline + a sticky horizontal mini-map.
 */
import type { Page, TestInfo } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(__dirname, '..', 'screenshots', '__story')

export interface StoryStep {
  idx: number
  title: string
  description: string
  file: string
  at: number
  durationMs: number
}

export interface Story {
  dir: string
  testTitle: string             // legacy — full Playwright test title path
  title: string                 // friendly run title
  description: string           // friendly run description
  startedAt: number
  steps: StoryStep[]
}

export interface StepInfo { title: string; description?: string }

function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)
}

export function newStory(testInfo: TestInfo, info?: { title?: string; description?: string }): Story {
  const testSlug = slug(testInfo.titlePath.join(' '))
  const dir = path.join(ROOT, testSlug)
  fs.rmSync(dir, { recursive: true, force: true })
  fs.mkdirSync(dir, { recursive: true })
  return {
    dir,
    testTitle: testInfo.titlePath.join(' › '),
    title: info?.title ?? testInfo.title,
    description: info?.description ?? '',
    startedAt: Date.now(),
    steps: [],
  }
}

type StepAction = string | (() => Promise<void> | void) | undefined

function persist(story: Story) {
  fs.writeFileSync(
    path.join(story.dir, 'story.json'),
    JSON.stringify({
      testTitle: story.testTitle,
      title: story.title,
      description: story.description,
      startedAt: story.startedAt,
      steps: story.steps,
    }, null, 2),
  )
}

export async function step(
  story: Story,
  page: Page,
  info: string | StepInfo,
  action?: StepAction,
): Promise<void> {
  const { title, description } = typeof info === 'string'
    ? { title: info, description: '' }
    : { title: info.title, description: info.description ?? '' }

  const t0 = Date.now()
  if (typeof action === 'string') {
    await page.goto(action)
  } else if (typeof action === 'function') {
    await action()
  }
  await page.waitForTimeout(150)

  const idx = story.steps.length
  const file = `${String(idx).padStart(2, '0')}-${slug(title)}.png`
  await page.screenshot({ path: path.join(story.dir, file), fullPage: false })
  story.steps.push({
    idx,
    title,
    description,
    file,
    at: Date.now(),
    durationMs: Date.now() - t0,
  })
  persist(story)
}
