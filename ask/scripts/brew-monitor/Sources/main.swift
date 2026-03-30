import Foundation
import Darwin

// Ignore SIGPIPE so a broken stdout pipe doesn't crash the process.
signal(SIGPIPE, SIG_IGN)

let mcp     = MCPClient()
let monitor = BrewMonitor(mcp: mcp)

await withTaskGroup(of: Void.self) { group in
    group.addTask { await mcp.readLoop() }
    group.addTask {
        do {
            try await mcp.initialize()
        } catch {
            fputs("[brew-monitor] init failed: \(error)\n", stderr)
            return
        }
        await monitor.run()
    }
}
