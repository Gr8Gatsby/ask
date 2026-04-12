import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import type { Block } from '../../src/lib/types.js'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SCRIPTS_DIR = path.resolve(__dirname, '../../../ask/scripts')

function loadScriptIcon(scriptID: string): string | undefined {
  try {
    const svgPath = path.join(SCRIPTS_DIR, scriptID, 'icon.svg')
    let svg = fs.readFileSync(svgPath, 'utf-8').trim()
    // Ensure the SVG fills its container
    svg = svg.replace(/\s(width|height)="[^"]*"/g, '')
    svg = svg.replace('<svg', '<svg width="100%" height="100%"')
    return svg
  } catch {
    return undefined
  }
}

function loadScriptName(scriptID: string, fallback: string): string {
  try {
    const manifestPath = path.join(SCRIPTS_DIR, scriptID, 'manifest.json')
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf-8'))
    return manifest.name ?? fallback
  } catch {
    return fallback
  }
}

export const CLAUDE3_ICON = loadScriptIcon('claude-3')
export const CLAUDE3_NAME = loadScriptName('claude-3', 'Claude Code')
export const BREW_ICON = loadScriptIcon('brew-monitor')
export const BREW_NAME = loadScriptName('brew-monitor', 'Brew Monitor')

function block(partial: Omit<Block, 'machineID' | 'createdAt' | 'requiresResponse' | 'showsInInbox'> & {
  requiresResponse?: number
  showsInInbox?: number
}): Block {
  return {
    machineID: 'mac-live',
    createdAt: new Date().toISOString(),
    requiresResponse: 0,
    showsInInbox: 0,
    ...partial,
  }
}

// ---- Brew Monitor fixture blocks (brew-monitor has no live daemon state) ----

export const FIXTURE_BREW_BLOCKS: Block[] = [
  block({
    blockID: 'brew-tile',
    scriptID: 'brew-monitor',
    scriptName: BREW_NAME,
    scriptIconSVG: BREW_ICON,
    blockType: 'tile',
    scriptType: 'tile',
    payload: JSON.stringify({ label: '3 updates available', status_color: 'orange', action_required: true }),
  }),
  block({
    blockID: 'brew-alert',
    scriptID: 'brew-monitor',
    scriptName: BREW_NAME,
    scriptIconSVG: BREW_ICON,
    blockType: 'alert',
    scriptType: 'tile',
    payload: JSON.stringify({
      title: 'Security Update Available',
      body: 'openssl has a critical security patch. Run `brew upgrade openssl` to update.',
      urgency: 'urgent',
    }),
  }),
  block({
    blockID: 'brew-countdown',
    scriptID: 'brew-monitor',
    scriptName: BREW_NAME,
    scriptIconSVG: BREW_ICON,
    blockType: 'countdown',
    scriptType: 'tile',
    payload: JSON.stringify({
      label: 'Auto-update in',
      time: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
    }),
  }),
  block({
    blockID: 'brew-quick-reply',
    scriptID: 'brew-monitor',
    scriptName: BREW_NAME,
    scriptIconSVG: BREW_ICON,
    blockType: 'quick_reply',
    scriptType: 'tile',
    requiresResponse: 1,
    showsInInbox: 1,
    payload: JSON.stringify({
      title: 'Update 3 outdated packages?',
      description: 'openssl, git, node — total ~240MB',
      options: ['Update All', 'Skip'],
      allow_custom: false,
      urgency: 'warning',
    }),
  }),
]

// Keep FIXTURE_BLOCKS as alias for backward compat (server.ts import)
export const FIXTURE_BLOCKS = FIXTURE_BREW_BLOCKS
