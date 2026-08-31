import spacesdevicecore
import spacesterminalcore

extension TerminalServiceDaemonStatus {
    public static let testStatus = TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0)
}

extension SpacesDeviceOverviewPayload {
    /// Test convenience: overview fixtures under test never exercise the inline daemon status.
    public init(
        projects: [SpacesDeviceProjectSummary] = [], workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary],
        retainedTerminalSessionIDs: [String] = [], workspaceIDsWithTeardownInFlight: [String] = []
    ) {
        self.init(
            projects: projects, workspaces: workspaces, sessions: sessions, retainedTerminalSessionIDs: retainedTerminalSessionIDs,
            workspaceIDsWithTeardownInFlight: workspaceIDsWithTeardownInFlight, daemonStatus: .testStatus)
    }
}
