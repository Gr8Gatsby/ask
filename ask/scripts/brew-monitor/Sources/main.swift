import Foundation
import Darwin

// Ignore SIGPIPE so a broken stdout pipe doesn't crash the process.
signal(SIGPIPE, SIG_IGN)

let mcp     = MCPClient()
let monitor = BrewMonitor(mcp: mcp)

// Read stdin in the background so MCP responses can be delivered while
// monitor.run() is awaiting user input. The task is abandoned on exit.
Task { await mcp.readLoop() }

do {
    try await mcp.initialize()
} catch {
    fputs("[brew-monitor] init failed: \(error)\n", stderr)
    exit(1)
}

await monitor.run()
// Script exits here — one-shot complete.
