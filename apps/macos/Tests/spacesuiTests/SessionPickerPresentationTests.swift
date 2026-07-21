import Foundation
import Testing
import spacesdevicecore
import workspacecore

@testable import spacesterminalcore
@testable import spacesui

/// Exercises the pure `AppKitController.sessionPickerPresentation` static core — the shared
/// row-builder behind ⌘T, the tab strip's "+", and split-right/split-down — without a live
/// AppKitController. `openSessionIDs` is the not-open-anywhere filter (`PanelCoordinator.openSessionIDs()`
/// in production); everything else mirrors what the instance wrapper gathers from overviews.
@Suite struct SessionPickerPresentationTests {
    private func session(id: String, workspaceID: String) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: id, workingDirectory: "/srv/\(workspaceID)", shell: "/bin/zsh", command: nil, state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: nil, workspaceID: workspaceID,
            workspaceTitle: "Feature", projectID: "project-1", projectName: "Project", createdAt: "2026-06-22T12:00:00Z",
            updatedAt: "2026-06-22T12:00:05Z", isControlAvailable: true, isSubscriptionAvailable: true,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .liveSession)
    }

    private func workspace(id: String) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/srv/\(id)", isRunning: true,
            isArchived: false, isHidden: false, isDefault: false, sessionCount: 0)
    }

    @Test func hidesOpenSessionAndSurfacesRemainingChoices() {
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [workspace(id: "workspace-1")],
            sessions: [session(id: "a", workspaceID: "workspace-1"), session(id: "b", workspaceID: "workspace-1"),
                session(id: "c", workspaceID: "workspace-1")])

        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: overview, scopedOverviews: [overview],
            limitToWorkspaceID: "workspace-1", openSessionIDs: ["b"])

        #expect(presentation.items.map(\.id) == ["picker:new", "picker:a", "picker:c"])
        guard case .existingSession(let request)? = presentation.choices["picker:a"] else {
            Issue.record("expected an existingSession choice for picker:a")
            return
        }
        #expect(request.sessionID == "a")
        guard case .newTerminalSession(let workspaceID)? = presentation.choices["picker:new"] else {
            Issue.record("expected a newTerminalSession choice for picker:new")
            return
        }
        #expect(workspaceID == "workspace-1")
    }

    @Test func workspaceScopeExcludesOtherWorkspacesSessions() {
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [workspace(id: "workspace-1"), workspace(id: "workspace-2")],
            sessions: [session(id: "session-mine", workspaceID: "workspace-1"), session(id: "session-other", workspaceID: "workspace-2")])

        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: overview, scopedOverviews: [overview],
            limitToWorkspaceID: "workspace-1", openSessionIDs: [])

        #expect(presentation.items.map(\.id) == ["picker:new", "picker:session-mine"])
    }

    @Test func globalScopeAcrossTwoOverviewsExcludesOpenSessionsFromEither() {
        let overviewA = SpacesDeviceOverviewPayload(
            workspaces: [workspace(id: "workspace-1")],
            sessions: [session(id: "session-a1", workspaceID: "workspace-1"), session(id: "session-a2", workspaceID: "workspace-1")])
        let overviewB = SpacesDeviceOverviewPayload(
            workspaces: [workspace(id: "workspace-2")], sessions: [session(id: "session-b1", workspaceID: "workspace-2")])

        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: overviewA, scopedOverviews: [overviewA, overviewB],
            limitToWorkspaceID: nil, openSessionIDs: ["session-a2"])

        #expect(presentation.items.map(\.id) == ["picker:new", "picker:session-a1", "picker:session-b1"])
    }

    @Test func allSessionsOpenStillShowsTheSingleNewTerminalRow() {
        let overview = SpacesDeviceOverviewPayload(
            workspaces: [workspace(id: "workspace-1")],
            sessions: [session(id: "session-a", workspaceID: "workspace-1"), session(id: "session-b", workspaceID: "workspace-1")])

        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: overview, scopedOverviews: [overview],
            limitToWorkspaceID: "workspace-1", openSessionIDs: ["session-a", "session-b"])

        #expect(presentation.items.map(\.id) == ["picker:new"])
        guard case .newTerminalSession? = presentation.choices["picker:new"] else {
            Issue.record("expected a newTerminalSession choice even with every session open")
            return
        }
    }
}
