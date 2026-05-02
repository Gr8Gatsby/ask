import { test } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// Visits every primary route and writes a full-page PNG to e2e/screenshots/.
// Read these from the agent (or browse them locally) to spot UI regressions
// at a glance. The agent uses the Read tool with the .png path to actually
// view the rendering — text-only API checks miss visual bugs like the
// "headless" badge mislabel that prompted this skill.

const OUT_DIR = path.join(__dirname, 'screenshots')
fs.mkdirSync(OUT_DIR, { recursive: true })

async function tour(page: import('@playwright/test').Page, route: string, filename: string) {
  await page.goto(route)
  await page.waitForTimeout(800)  // let SSE seed + initial fetches resolve
  await page.screenshot({ path: path.join(OUT_DIR, filename), fullPage: true })
}

test.describe('screenshot tour @manual', () => {
  test('iOS theme — every primary route', async ({ page }) => {
    // Default theme is iOS. Routes: /, /home, /tasks, /settings, /script/<id>
    await tour(page, '/',         '01-root.png')
    await tour(page, '/home',     '02-home.png')
    await tour(page, '/tasks',    '03-tasks.png')
    await tour(page, '/settings', '04-settings.png')
    await tour(page, '/script/claude-3', '05-script-claude-3.png')
    await tour(page, '/script/codex-3',  '06-script-codex-3.png')
  })

  test('script detail at narrow viewport — frame must not clip', async ({ page }) => {
    await page.setViewportSize({ width: 1100, height: 600 })
    await tour(page, '/script/claude-3', '07-narrow-claude-3.png')
  })
})
