import { test, expect } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import { newStory, step } from './helpers/story'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const HOME = process.env.HOME!
const CODEX_LOG = path.join(HOME, '.ask/logs/codex-3.log')

test('codex agent_session — type a probe in the UI, daemon routes it', async ({ page, request }, testInfo) => {
  const story = newStory(testInfo, {
    title: 'Sending a message to a live Codex session from the web app',
    description:
      'Drives the same chat UI a user would touch on the iPhone or browser — ' +
      'navigates into the live Codex session, types a probe, presses Enter, ' +
      'and confirms the daemon routed it and the tmux pane received the keystrokes. ' +
      'A green run here means the iPhone → AskMac → daemon → tmux path is healthy end-to-end.',
  })

  const blocks = (await (await request.get('/api/blocks')).json()) as { blocks: Array<{ blockID: string; payload: string }> }
  const sessionBlock = blocks.blocks.find(b => b.blockID.startsWith('codex3-session-'))
  test.skip(!sessionBlock, 'no live codex agent_session block')
  if (!sessionBlock) return

  const payload = JSON.parse(sessionBlock.payload) as { session_id: string; tmux_target?: string | null }
  const SESSION_ID = payload.session_id
  const TMUX_TARGET = payload.tmux_target || 'codex:skills.0'
  const PROBE = `ui-probe-${Date.now()}-${Math.floor(Math.random() * 1e4)}`
  const offset = fs.statSync(CODEX_LOG).size

  await step(story, page, {
    title: 'Open the Codex chat',
    description:
      'Land on the conversation thread for the live session. Expect to see the ' +
      'prior chat history and a reply input pinned at the bottom.',
  }, `/script/codex-3/session/${encodeURIComponent(SESSION_ID)}`)

  const input = page.getByPlaceholder(/Message Codex|Reply|Message Claude/i).first()
  await expect(input).toBeVisible({ timeout: 5000 })

  await step(story, page, {
    title: 'Click into the reply input',
    description: 'The cursor should land in the message box; placeholder fades.',
  }, async () => {
    await input.click()
  })

  await step(story, page, {
    title: 'Type a test message',
    description:
      'A short probe string is typed character-by-character. The blue user-bubble ' +
      'will only appear after submission, so this step is mostly verifying that ' +
      'the input accepts text.',
  }, async () => {
    await input.fill(PROBE)
  })

  await step(story, page, {
    title: 'Send the message',
    description:
      'Pressing Enter ships the message through to the daemon. Within a couple ' +
      'of seconds you should see the user bubble and a "Working…" indicator below.',
  }, async () => {
    await input.press('Enter')
    await page.waitForTimeout(2000)
  })

  // ----- assertions: daemon log, tmux pane, plus a final story shot -----
  const newLog = fs.readFileSync(CODEX_LOG).slice(offset).toString()
  expect(newLog).toMatch(/block response/)
  expect(newLog).toMatch(new RegExp(`reply session=.*ok=True.*${PROBE}`))

  const { execSync } = await import('child_process')
  const tmuxOutput = execSync(`tmux capture-pane -t '${TMUX_TARGET}' -p`).toString()
  expect(tmuxOutput).toContain(PROBE)

  await step(story, page, {
    title: 'Confirm Codex received the message',
    description:
      'Behind the scenes we just checked the codex-3 daemon log for "reply ok=True" ' +
      'and captured the codex tmux pane to confirm the probe text actually arrived. ' +
      'If you see this step, the full chain — UI → AskMac HTTP → daemon socket → ' +
      'terminal-manager → tmux → agent — is working.',
  })
})
