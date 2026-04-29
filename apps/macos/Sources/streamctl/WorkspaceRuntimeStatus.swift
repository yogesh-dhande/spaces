import Foundation

public struct WorkspaceRuntimeStatus: Sendable {
    public let workspaceID: String
    public let lifecycleState: WorkspaceLifecycleState
    public let runtimeHealth: WorkspaceRuntimeHealth
    public let hasTrackedRuntimeIndicators: Bool
    public let runningProcessCount: Int
    public let exitedProcessCount: Int
    public let waitingAgentWindowCount: Int
    public let missingConfiguredProcessCount: Int
    public let missingConfiguredBrowserSessionCount: Int

    public init(
        workspaceID: String, lifecycleState: WorkspaceLifecycleState, runtimeHealth: WorkspaceRuntimeHealth, hasTrackedRuntimeIndicators: Bool,
        runningProcessCount: Int, exitedProcessCount: Int, waitingAgentWindowCount: Int, missingConfiguredProcessCount: Int,
        missingConfiguredBrowserSessionCount: Int
    ) {
        self.workspaceID = workspaceID
        self.lifecycleState = lifecycleState
        self.runtimeHealth = runtimeHealth
        self.hasTrackedRuntimeIndicators = hasTrackedRuntimeIndicators
        self.runningProcessCount = runningProcessCount
        self.exitedProcessCount = exitedProcessCount
        self.waitingAgentWindowCount = waitingAgentWindowCount
        self.missingConfiguredProcessCount = missingConfiguredProcessCount
        self.missingConfiguredBrowserSessionCount = missingConfiguredBrowserSessionCount
    }

    public var isDegraded: Bool {
        switch runtimeHealth {
        case .healthy: false
        case .partial, .missing: true
        }
    }

    public var warningSummary: String? {
        var parts: [String] = []

        switch lifecycleState {
        case .stopped: if hasTrackedRuntimeIndicators { parts.append("tracked runtime leftovers") }
        case .running:
            switch runtimeHealth {
            case .healthy: break
            case .missing: parts.append("no tracked runtime remains")
            case .partial:
                if missingConfiguredProcessCount > 0 {
                    parts.append(summaryCount(missingConfiguredProcessCount, singular: "missing process", plural: "missing processes"))
                }
                if exitedProcessCount > 0 { parts.append(summaryCount(exitedProcessCount, singular: "exited process", plural: "exited processes")) }
                if waitingAgentWindowCount > 0 {
                    parts.append(summaryCount(waitingAgentWindowCount, singular: "waiting agent", plural: "waiting agents"))
                }
            }
        }

        guard !parts.isEmpty else { return nil }
        return parts.prefix(3).joined(separator: ", ")
    }

    private func summaryCount(_ count: Int, singular: String, plural: String) -> String { "\(count) \(count == 1 ? singular : plural)" }
}
