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
        liveSessions: [TerminalSessionCatalogEntry], automationAttributedSessionIDs: [String] = []
    ) -> SpacesDeviceOverviewPayload {
        build(
            projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: liveSessions, daemonStatus: .testStatus,
            automationAttributedSessionIDs: automationAttributedSessionIDs)
    }

    /// Builds the payload the daemon actually serves: the server derives the workspace terminal rows from
    /// the product records first, and the builder renders them. Tests that care which sessions a client
    /// can see must go through this rather than passing `workspaceRows` themselves, since whether a row
    /// exists at all is the daemon's decision. `retainedSessions` stands in for the persisted entries
    /// `terminalCatalogEntry` reads off disk for a session the live catalog no longer carries.
    static func buildWithServerRows(
        projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], liveSessions: [TerminalSessionCatalogEntry],
        retainedSessions: [TerminalSessionCatalogEntry] = [], sessionIDsWithFinalRender: Set<String> = []
    ) -> SpacesDeviceOverviewPayload {
        let retainedByID = Dictionary(retainedSessions.map { ($0.sessionID, $0) }, uniquingKeysWith: { existing, _ in existing })
        let rows = SpacesDeviceAPIServer.workspaceTerminalRows(
            workspaces: workspaces, sessions: liveSessions, sessionIDsWithFinalRender: sessionIDsWithFinalRender, catalogEntry: { retainedByID[$0] },
            endedWindowSessions: retainedByID)
        return build(projects: projects, workspaces: workspaces, workspaceRows: rows, liveSessions: liveSessions, daemonStatus: .testStatus)
    }
}
