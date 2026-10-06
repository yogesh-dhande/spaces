import Foundation
import workspacecore

/// Restart-impact tallies a daemon restart would destroy. Shared by the standalone frozen-core
/// `loadDaemonStatus` and the inline status attached to the overview so both report the same
/// counts from whichever scan already loaded the records.
struct RestartImpactCounts {
    var runningProcesses = 0
    var activeAgents = 0
    var waitingAgents = 0

    mutating func accumulate(runningProcesses processes: [RunningProcessRecord], agentWindows: [AgentWindowRecord]) {
        runningProcesses += processes.filter { $0.status == .running }.count
        for agent in agentWindows {
            switch agent.status {
            case .spinning: activeAgents += 1
            case .waiting: waitingAgents += 1
            // Exited counts as no live agent work, like idle/done: a restart destroys nothing for it.
            case .idle, .done, .exited: break
            }
        }
    }
}
