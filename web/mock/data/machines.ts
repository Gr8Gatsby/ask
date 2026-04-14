import type { Machine } from '../../src/lib/types.js'

export const FIXTURE_MACHINES: Machine[] = [
  {
    machineID: 'mac-dev-1',
    name: "Kevin's MacBook Pro",
    platform: 'macOS',
    lastHeartbeat: new Date().toISOString(),
    status: 'busy',
  },
]
