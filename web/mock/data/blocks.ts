import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SCRIPTS_DIR = path.resolve(__dirname, '../../../ask/scripts')

function loadScriptIcon(scriptID: string): string | undefined {
  try {
    const svgPath = path.join(SCRIPTS_DIR, scriptID, 'icon.svg')
    let svg = fs.readFileSync(svgPath, 'utf-8').trim()
    // Strip width, height, and inline style from the root <svg> element so the
    // icon fills whatever container ScriptIcon places it in.
    svg = svg.replace(/\s+(width|height|style)="[^"]*"/g, '')
    svg = svg.replace('<svg', '<svg width="100%" height="100%" style="display:block"')
    // Replace hardcoded black fills with currentColor so the icon inherits the
    // container's text color and adapts to light/dark themes automatically.
    svg = svg.replace(/fill="(#000000|#000|black)"/gi, 'fill="currentColor"')
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

// Used by server.ts for brew fixture simulation responses
export const BREW_ICON = loadScriptIcon('brew-monitor')
export const BREW_NAME = loadScriptName('brew-monitor', 'Brew Monitor')
