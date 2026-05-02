import { test, expect } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SHOTS = path.join(__dirname, 'screenshots', 'roundtrip')
fs.mkdirSync(SHOTS, { recursive: true })

const HOME = process.env.HOME!
const CODEX_LOG = path.join(HOME, '.ask/logs/codex-3.log')

// Real "manual" round trip via the UI:
//   open /  →  navigate to a codex session  →  type a probe  →  hit send
//   →  verify the daemon log shows it routed
//   →  verify the tmux pane received the keystrokes
// Screenshots before/after every step land in screenshots/roundtrip/.

test('codex agent_session — type a probe in the UI, daemon routes it', async ({ page, request }) => {
  // Pick a live codex agent_session block via the API (whatever the backend says is live)
  const blocks = (await (await request.get('/api/blocks')).json()) as { blocks: Array<{ blockID: string; payload: string }> }
  const sessionBlock = blocks.blocks.find(b => b.blockID.startsWith('codex3-session-'))
  test.skip(!sessionBlock, 'no live codex agent_session block; nothing to drive')
  if (!sessionBlock) return

  const payload = JSON.parse(sessionBlock.payload) as { session_id: string; tmux_target?: string | null }
  const SESSION_ID = payload.session_id
  const TMUX_TARGET = payload.tmux_target || 'codex:skills.0'
  const PROBE = `ui-probe-${Date.now()}-${Math.floor(Math.random() * 1e4)}`
  const offset = fs.statSync(CODEX_LOG).size

  // Navigate to the session chat screen (the real route the UI uses)
  await page.goto(`/script/codex-3/session/${encodeURIComponent(SESSION_ID)}`)
  await page.waitForTimeout(1000)
  await page.screenshot({ path: path.join(SHOTS, '01-chat-loaded.png'), fullPage: true })

  // Find the reply input. The placeholder text in the codex agent_session
  // block is set by the daemon; fall back to a generic Message…/Reply… match.
  const input = page.getByPlaceholder(/Message Codex|Reply|Message Claude/i).first()
  await expect(input).toBeVisible({ timeout: 5000 })
  await input.fill(PROBE)
  await page.screenshot({ path: path.join(SHOTS, '02-probe-typed.png'), fullPage: true })

  // Submit. iOS variant has the input + a circular send button next to it
  // (via SessionChatScreen.tsx); the simplest trigger is Enter.
  await input.press('Enter')
  await page.waitForTimeout(2000) // round trip + assistant first-token
  await page.screenshot({ path: path.join(SHOTS, '03-after-send.png'), fullPage: true })

  // Verify the daemon routed it
  const newLog = fs.readFileSync(CODEX_LOG).slice(offset).toString()
  expect(newLog).toMatch(/block response/)
  expect(newLog).toMatch(new RegExp(`reply session=.*ok=True.*${PROBE}`))

  // Verify the tmux pane received the probe text
  const { execSync } = await import('child_process')
  const tmux = execSync(`tmux capture-pane -t '${TMUX_TARGET}' -p`).toString()
  expect(tmux).toContain(PROBE)
})
