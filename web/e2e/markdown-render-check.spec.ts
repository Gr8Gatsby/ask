import { test } from '@playwright/test'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SHOTS = path.join(__dirname, 'screenshots', 'annotated')
fs.mkdirSync(SHOTS, { recursive: true })

// Annotated screenshot: navigate to a live codex session, then have the page
// outline every rendered markdown element produced by react-markdown so we
// can SEE that <code>, <strong>, <pre>, <h1>...<h3> are actually there in the
// DOM (not raw asterisks/backticks). Output saved to e2e/screenshots/annotated/.

test('markdown renders in assistant messages — annotated proof', async ({ page, request }) => {
  const blocks = (await (await request.get('/api/blocks')).json()) as { blocks: Array<{ blockID: string; payload: string }> }
  const sb = blocks.blocks.find(b => b.blockID.startsWith('codex3-session-')) || blocks.blocks.find(b => b.blockID.startsWith('claude3-session-'))
  test.skip(!sb, 'no live agent_session block')
  if (!sb) return

  const payload = JSON.parse(sb.payload) as { session_id: string }
  const scriptID = sb.blockID.startsWith('claude3-') ? 'claude-3' : 'codex-3'
  await page.goto(`/script/${scriptID}/session/${encodeURIComponent(payload.session_id)}`)
  await page.waitForTimeout(1500)

  // Inject overlays: outline + label every rendered markdown element type.
  // If markdown WERE NOT rendering, the page would have raw asterisks and
  // backticks as plain text and these selectors would match nothing.
  const summary = await page.evaluate(() => {
    const colors: Record<string, string> = {
      'strong':     '#ff3b30',  // red
      'em':         '#ff9500',  // orange
      'code':       '#34c759',  // green — inline code
      'pre':        '#007aff',  // blue — code block
      'h1, h2, h3': '#af52de',  // purple — headings
      'ul, ol':     '#5ac8fa',  // cyan — lists
      'blockquote': '#ffcc00',  // yellow — quotes
      'a':          '#ff2d55',  // pink — links
    }
    const counts: Record<string, number> = {}
    for (const [sel, color] of Object.entries(colors)) {
      const els = document.querySelectorAll(sel)
      counts[sel] = els.length
      els.forEach(el => {
        ;(el as HTMLElement).style.outline = `2px solid ${color}`
        ;(el as HTMLElement).style.outlineOffset = '2px'
      })
    }
    // Add a legend in the top-left corner
    const legend = document.createElement('div')
    legend.style.cssText = `
      position: fixed; top: 8px; left: 8px; z-index: 99999;
      background: rgba(20,20,20,0.95); color: #fff; font: 12px/1.4 ui-monospace,monospace;
      padding: 10px 12px; border-radius: 8px; box-shadow: 0 4px 12px rgba(0,0,0,0.4);
    `
    legend.innerHTML = `
      <div style="font-weight:700;margin-bottom:6px">Rendered markdown elements found:</div>
      ${Object.entries(colors).map(([sel, color]) =>
        `<div><span style="display:inline-block;width:10px;height:10px;background:${color};margin-right:6px;border-radius:2px"></span><code style="color:#fff">${sel}</code> — <strong>${counts[sel]}</strong></div>`
      ).join('')}
    `
    document.body.appendChild(legend)
    return counts
  })

  console.log('markdown element counts:', summary)
  await page.screenshot({ path: path.join(SHOTS, 'markdown-rendered.png'), fullPage: true })
})
