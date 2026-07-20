import spacesdevicecore
import spacesterminalcore

extension TerminalServiceDaemonStatus {
    static let testStatus = TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0)
}

extension SpacesDeviceOverviewPayload {
    /// Test convenience: overview fixtures under test never exercise the inline daemon status.
    init(
        projects: [SpacesDeviceProjectSummary] = [], workspaces: [SpacesDeviceWorkspaceSummary],
        sessions: [SpacesDeviceTerminalSessionSummary], retainedTerminalSessionIDs: [String] = []
    ) {
        self.init(
            projects: projects, workspaces: workspaces, sessions: sessions, retainedTerminalSessionIDs: retainedTerminalSessionIDs,
            daemonStatus: .testStatus)
    }
}
