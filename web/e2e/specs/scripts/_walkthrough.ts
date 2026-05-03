/**
 * Plan-driven walkthrough executor.
 *
 * The plan JSON at web/review-plans/manual-script-sweep.json is the single
 * source of truth for per-case steps (titles, descriptions, and execution
 * directives like `nav` or `waitMs`). A spec passes its caseId; the helper
 * looks the case up, opens a story, and walks the declared steps in order.
 *
 * This means the dashboard's case-detail page and the slideshow show the
 * same step list — declared steps, executed steps, and pinned-comment
 * targets all agree.
 */
import type { Page, TestInfo } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { newStory, step } from '../../helpers/story'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const PLAN_PATH = path.resolve(__dirname, '..', '..', '..', 'review-plans', 'manual-script-sweep.json')

interface PlanStep {
  id: string
  title: string
  description: string
  nav?: string
  waitMs?: number
}
interface PlanCase {
  id: string
  surface: 'web' | 'askmac'
  title: string
  description?: string
  steps?: PlanStep[]
}
interface Plan { cases: PlanCase[] }

function loadPlan(): Plan {
  return JSON.parse(fs.readFileSync(PLAN_PATH, 'utf-8')) as Plan
}

export function getCase(caseId: string): PlanCase {
  const plan = loadPlan()
  const c = plan.cases.find(x => x.id === caseId)
  if (!c) throw new Error(`case "${caseId}" not declared in plan ${PLAN_PATH}`)
  return c
}

/** Walk a web case's declared steps. Each step is one screenshot + HTML. */
export async function runWebCase(page: Page, testInfo: TestInfo, caseId: string): Promise<void> {
  const c = getCase(caseId)
  if (c.surface !== 'web') throw new Error(`case "${caseId}" surface=${c.surface}, expected web`)
  if (!c.steps?.length) throw new Error(`case "${caseId}" has no declared steps`)

  const story = newStory(testInfo, {
    caseId: c.id,
    title: c.title,
    description: c.description ?? '',
  })

  for (const s of c.steps) {
    await step(story, page, { title: s.title, description: s.description }, async () => {
      if (s.nav) await page.goto(s.nav)
      if (typeof s.waitMs === 'number') await page.waitForTimeout(s.waitMs)
    })
  }
}
