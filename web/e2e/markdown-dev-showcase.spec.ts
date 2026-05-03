import { test } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SHOTS = path.join(__dirname, 'screenshots', 'markdown-showcase')
fs.mkdirSync(SHOTS, { recursive: true })

test('markdown showcase — renders every styled element via /dev/markdown', async ({ page }) => {
  await page.goto('/dev/markdown')
  await page.waitForTimeout(800)

  // Capture only the inner scroll container of the phone screen, in
  // segments — the frame itself is fixed-height so fullPage doesn't help.
  const inner = page.locator('#phone-screen .overflow-y-auto').first()
  await inner.evaluate((el) => { el.scrollTop = 0 })
  await page.screenshot({ path: path.join(SHOTS, 'after-1-top.png'), fullPage: false, clip: await inner.boundingBox() ?? undefined })

  await inner.evaluate((el) => { el.scrollTop = el.scrollHeight / 3 })
  await page.waitForTimeout(200)
  await page.screenshot({ path: path.join(SHOTS, 'after-2-mid.png'), fullPage: false, clip: await inner.boundingBox() ?? undefined })

  await inner.evaluate((el) => { el.scrollTop = (el.scrollHeight * 2) / 3 })
  await page.waitForTimeout(200)
  await page.screenshot({ path: path.join(SHOTS, 'after-3-mid2.png'), fullPage: false, clip: await inner.boundingBox() ?? undefined })

  await inner.evaluate((el) => { el.scrollTop = el.scrollHeight })
  await page.waitForTimeout(200)
  await page.screenshot({ path: path.join(SHOTS, 'after-4-bottom.png'), fullPage: false, clip: await inner.boundingBox() ?? undefined })
})
