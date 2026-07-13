import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesdeviceapi

extension TerminalServiceDaemonStatus {
    static let testStatus = TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0)
}

extension SpacesDeviceOverviewPayload {
    /// Test convenience: overview fixtures under test never exercise the inline daemon status.
    init(projects: [SpacesDeviceProjectSummary] = [], workspaces: [SpacesDeviceWorkspaceSummary], sessions: [SpacesDeviceTerminalSessionSummary]) {
        self.init(projects: projects, workspaces: workspaces, sessions: sessions, daemonStatus: .testStatus)
    }
}

extension SpacesDeviceOverviewBuilder {
    static func build(projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry])
        -> SpacesDeviceOverviewPayload
    { build(projects: projects, workspaces: workspaces, workspaceRows: [], liveSessions: sessions, daemonStatus: .testStatus) }

    static func build(
        projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], workspaceRows: [WorkspaceTerminalRow],
        liveSessions: [TerminalSessionCatalogEntry]
    ) -> SpacesDeviceOverviewPayload {
        build(projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: liveSessions, daemonStatus: .testStatus)
    }
}
