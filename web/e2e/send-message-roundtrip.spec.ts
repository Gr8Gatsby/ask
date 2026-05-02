import { test, expect } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { newStory, step } from './helpers/story'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const HOME = process.env.HOME!
const CODEX_LOG = path.join(HOME, '.ask/logs/codex-3.log')

// Records a per-step "story" of what we did, with a screenshot at each
// step. The review dashboard renders this as a vertical timeline so a
// human can see the actions taken between screens, not just an end state.
test('codex agent_session — type a probe in the UI, daemon routes it', async ({ page, request }, testInfo) => {
  const story = newStory(testInfo)

  const blocks = (await (await request.get('/api/blocks')).json()) as { blocks: Array<{ blockID: string; payload: string }> }
  const sessionBlock = blocks.blocks.find(b => b.blockID.startsWith('codex3-session-'))
  test.skip(!sessionBlock, 'no live codex agent_session block')
  if (!sessionBlock) return

  const payload = JSON.parse(sessionBlock.payload) as { session_id: string; tmux_target?: string | null }
  const SESSION_ID = payload.session_id
  const TMUX_TARGET = payload.tmux_target || 'codex:skills.0'
  const PROBE = `ui-probe-${Date.now()}-${Math.floor(Math.random() * 1e4)}`
  const offset = fs.statSync(CODEX_LOG).size

  await step(story, page, 'Open codex chat for the live session',
    `/script/codex-3/session/${encodeURIComponent(SESSION_ID)}`)

  const input = page.getByPlaceholder(/Message Codex|Reply|Message Claude/i).first()
  await expect(input).toBeVisible({ timeout: 5000 })

  await step(story, page, 'Focus the reply input', async () => {
    await input.click()
  })

  await step(story, page, `Type the probe text "${PROBE}"`, async () => {
    await input.fill(PROBE)
  })

  await step(story, page, 'Press Enter to submit', async () => {
    await input.press('Enter')
    await page.waitForTimeout(2000)   // round trip + assistant first-token
  })

  // ----- assertions: daemon log, tmux pane, plus a final story shot -----
  const newLog = fs.readFileSync(CODEX_LOG).slice(offset).toString()
  expect(newLog).toMatch(/block response/)
  expect(newLog).toMatch(new RegExp(`reply session=.*ok=True.*${PROBE}`))

  const { execSync } = await import('child_process')
  const tmuxOutput = execSync(`tmux capture-pane -t '${TMUX_TARGET}' -p`).toString()
  expect(tmuxOutput).toContain(PROBE)

  await step(story, page, 'Verified: probe received in tmux + daemon log routed it')
})
