import spacesdevicecore
import spacesterminalcore

extension SpacesDeviceOverviewPayload {
    /// Test convenience: overview fixtures under test never exercise the inline daemon status, beyond
    /// the home directory paths are abbreviated against — which a fixture sets to the *owning device's*
    /// home, deliberately unrelated to the home the test process runs under.
    init(
        projects: [SpacesDeviceProjectSummary] = [], workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary],
        retainedTerminalSessionIDs: [String] = [], daemonHomeDirectory: String? = nil
    ) {
        self.init(
            projects: projects, workspaces: workspaces, sessions: sessions, retainedTerminalSessionIDs: retainedTerminalSessionIDs,
            daemonStatus: TerminalServiceDaemonStatus(
                version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, homeDirectory: daemonHomeDirectory))
    }
}
