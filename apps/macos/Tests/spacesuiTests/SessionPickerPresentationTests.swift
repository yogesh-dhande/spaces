import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesui

/// Exercises the pure `AppKitController.sessionPickerPresentation` static core — the shared
/// row-builder behind ⌘T, the tab strip's "+", and split-right/split-down — without a live
/// AppKitController. Rows are the workspace's sidebar runtime targets in sidebar order,
/// minus browsers (they can't live in a pane) and minus any target whose session already
/// occupies a pane (`openSessionIDs`, sourced from `PanelCoordinator.openSessionIDs()` in
/// production). Not-started configured processes carry a start choice and have no session, so they
/// always list.
@Suite struct SessionPickerPresentationTests {
    /// Sidebar target order for this fixture: browser(docs) → process(web) →
    /// missingConfiguredProcess(api) → agent(claude) → window(shell).
    /// Every id is suffixed with the workspace id so multiple workspaces stay distinguishable.
    private func richWorkspace(id: String) -> SpacesDeviceWorkspaceSummary {
        let config = SpacesDeviceWorkspaceConfig(
            processes: [
                SpacesDeviceProcessTemplate(id: "tpl-web-\(id)", name: "web", command: "npm run dev"),
                SpacesDeviceProcessTemplate(id: "tpl-api-\(id)", name: "api", command: "npm run api"),
            ], resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "docs", url: "http://localhost:3000")])
        return SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/\(id)", isRunning: true,
            isHidden: false, isDefault: false, sessionCount: 3, config: config,
            processRows: [
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-web-\(id)", workspaceID: id, name: "web", command: "npm run dev", templateID: "tpl-web-\(id)",
                    processID: "process-web-\(id)", sessionID: "session-web-\(id)", runState: .running, canRun: false, canStop: true, canRestart: true
                ),
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-api-\(id)", workspaceID: id, name: "api", command: "npm run api", templateID: "tpl-api-\(id)", processID: nil,
                    sessionID: nil, runState: .notStarted, canRun: true, canStop: false, canRestart: false),
            ],
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-\(id)", workspaceID: id, name: "claude", command: "claude", agentID: "agent-\(id)",
                    sessionID: "session-agent-\(id)", runState: .running, activityState: .idle, canStop: true)
            ],
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "row-shell-\(id)", workspaceID: id, title: "shell", workingDirectory: "/tmp/\(id)", sessionID: "session-shell-\(id)",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
    }

    private func context(for workspace: SpacesDeviceWorkspaceSummary, sessions: [SpacesDeviceTerminalSessionSummary] = [])
        -> AppKitController.SessionPickerWorkspaceContext
    {
        AppKitController.SessionPickerWorkspaceContext(
            workspaceID: workspace.id, overview: SpacesDeviceOverviewPayload(workspaces: [workspace], sessions: sessions))
    }

    private func terminalSessionSummary(id: String, title: String, foregroundCommand: String) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: title, workingDirectory: "/tmp/workspace-1", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 321, childPID: nil, workspaceID: "workspace-1", workspaceTitle: "Feature", projectID: "project",
            projectName: "Project", createdAt: "2026-08-14T12:00:00Z", updatedAt: "2026-08-14T12:00:01Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), foregroundCommand: foregroundCommand)
    }

    /// Hiding suppresses listing surfaces without tearing down open panels, so the global picker
    /// keeps the invoking pane's own workspace even when the sidebar-visible walk dropped it, and
    /// never duplicates it when the walk still lists it.
    @Test func globalScopeKeepsTheInvokingWorkspaceWhenHiddenFromTheVisibleWalk() {
        let invoking = richWorkspace(id: "workspace-invoking")
        let other = richWorkspace(id: "workspace-other")
        let invokingContext = context(for: invoking)
        let otherContext = context(for: other)

        let withHiddenInvoker = AppKitController.globalSessionPickerScopedWorkspaces(
            ordered: [otherContext], newTerminalWorkspaceID: "workspace-invoking", newTerminalOverview: invokingContext.overview)
        #expect(withHiddenInvoker.map(\.workspaceID) == ["workspace-invoking", "workspace-other"])

        let withListedInvoker = AppKitController.globalSessionPickerScopedWorkspaces(
            ordered: [otherContext, invokingContext], newTerminalWorkspaceID: "workspace-invoking", newTerminalOverview: invokingContext.overview)
        #expect(withListedInvoker.map(\.workspaceID) == ["workspace-other", "workspace-invoking"])
    }

    @Test func listsSidebarTargetsInOrderExcludingBrowsers() {
        let workspace = richWorkspace(id: "workspace-1")
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspace).overview, scopedWorkspaces: [context(for: workspace)],
            openSessionIDs: [])

        // "New terminal session" leads; the browser (docs) is dropped; everything else keeps sidebar order.
        #expect(
            presentation.items.map(\.id) == [
                "picker:new", "picker:workspace-1::1", "picker:workspace-1::2", "picker:workspace-1::3", "picker:workspace-1::4",
            ])
        #expect(presentation.items.map(\.label) == ["New terminal session", "web", "api", "claude", "shell"])
        #expect(presentation.items.map(\.kind) == [.window, .process, .missingConfiguredProcess, .agent, .window])
    }

    @Test func liveAndExitedTargetsResolveToExistingSessionRequestsBuiltLikeTheSidebar() {
        let workspace = richWorkspace(id: "workspace-1")
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspace).overview, scopedWorkspaces: [context(for: workspace)],
            openSessionIDs: [])

        // The configured process has no overview session entry, so the request is the fallback the
        // sidebar builds from the row (title, dir, kind) rather than an overview-derived one.
        guard case .existingSession(let webRequest)? = presentation.choices["picker:workspace-1::1"] else {
            Issue.record("expected an existingSession choice for the running process target")
            return
        }
        #expect(webRequest.sessionID == "session-web-workspace-1")
        #expect(webRequest.title == "web")
        #expect(webRequest.workingDirectory == "/tmp/workspace-1")
        #expect(webRequest.kind == .process)

        guard case .existingSession(let shellRequest)? = presentation.choices["picker:workspace-1::4"] else {
            Issue.record("expected an existingSession choice for the ad hoc terminal target")
            return
        }
        #expect(shellRequest.sessionID == "session-shell-workspace-1")
    }

    /// A not-started configured process is the only start choice the picker offers: an agent row is
    /// always a live session, so it can only ever resolve to that session.
    @Test func notStartedConfiguredProcessCarriesTheOnlyStartChoice() {
        let workspace = richWorkspace(id: "workspace-1")
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspace).overview, scopedWorkspaces: [context(for: workspace)],
            openSessionIDs: [])

        guard case .startProcess(let workspaceID, let processKey, let processTemplateID)? = presentation.choices["picker:workspace-1::2"] else {
            Issue.record("expected a startProcess choice for the not-started configured process")
            return
        }
        #expect(workspaceID == "workspace-1")
        #expect(processKey == "api")
        #expect(processTemplateID == "tpl-api-workspace-1")

        let startChoiceCount = presentation.choices.values.filter {
            if case .startProcess = $0 { return true }
            return false
        }.count
        #expect(startChoiceCount == 1)
    }

    @Test func excludesTargetsAlreadyOpenInAPaneButKeepsNotStartedRows() {
        let workspace = richWorkspace(id: "workspace-1")
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspace).overview, scopedWorkspaces: [context(for: workspace)],
            openSessionIDs: ["session-web-workspace-1", "session-shell-workspace-1"])

        // The two open sessions (web, shell) drop; the sessionless not-started row (api) and the
        // still-closed agent stay.
        #expect(presentation.items.map(\.label) == ["New terminal session", "api", "claude"])
    }

    @Test func everyTargetOpenLeavesOnlyTheNewTerminalRow() {
        // A workspace whose targets are all live sessions (no not-started rows): opening all of them
        // leaves the picker with just its create row.
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "workspace-1", projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/workspace-1",
            isRunning: true, isHidden: false, isDefault: false, sessionCount: 1,
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "row-shell", workspaceID: "workspace-1", title: "shell", workingDirectory: "/tmp/workspace-1", sessionID: "session-shell",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspace).overview, scopedWorkspaces: [context(for: workspace)],
            openSessionIDs: ["session-shell"])

        #expect(presentation.items.map(\.id) == ["picker:new"])
        guard case .newTerminalSession? = presentation.choices["picker:new"] else {
            Issue.record("expected a newTerminalSession choice even with every target open")
            return
        }
    }

    /// Picker rows describe an ad hoc shell the way the sidebar does: its name, then the title its
    /// program reported — nothing for a shell that has reported none.
    @Test func terminalRowsShowTheNameDescribedByTheLiveTitle() throws {
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "workspace-1", projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/device/workspace-1",
            isRunning: true, isHidden: false, isDefault: false, sessionCount: 2,
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "row-quiet", workspaceID: "workspace-1", title: "shell-1", workingDirectory: "/device/workspace-1",
                    sessionID: "session-quiet", runState: .running, canOpenTerminal: true, canStop: true),
                SpacesDeviceWorkspaceTerminalRow(
                    id: "row-busy", workspaceID: "workspace-1", title: "shell-2", workingDirectory: "/device/workspace-1", sessionID: "session-busy",
                    runState: .running, canOpenTerminal: true, canStop: true, liveTitle: "vim main.swift"),
            ])
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspace).overview, scopedWorkspaces: [context(for: workspace)],
            openSessionIDs: [])

        #expect(try #require(presentation.items.first { $0.label == "shell-1" }).detail == nil)
        #expect(try #require(presentation.items.first { $0.label == "shell-2" }).detail == "vim main.swift")
    }

    @Test func agentRowsPreferTheirOverviewLiveTitleThenSessionForegroundCommand() throws {
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "workspace-1", projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/workspace-1",
            isRunning: true, isHidden: false, isDefault: false, sessionCount: 2,
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:busy", workspaceID: "workspace-1", name: "Codex busy", command: "codex", agentID: "busy", sessionID: "session-busy",
                    runState: .running, activityState: .spinning, canStop: true, liveTitle: "reviewing PR 493"),
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:quiet", workspaceID: "workspace-1", name: "Codex quiet", command: "codex", agentID: "quiet",
                    sessionID: "session-quiet", runState: .running, activityState: .idle, canStop: true),
            ])
        let sessions = [
            terminalSessionSummary(id: "session-busy", title: "Codex busy", foregroundCommand: "ignored foreground"),
            terminalSessionSummary(id: "session-quiet", title: "Codex quiet", foregroundCommand: "codex --model gpt-5.6-sol"),
        ]
        let workspaceContext = context(for: workspace, sessions: sessions)

        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: workspaceContext.overview, scopedWorkspaces: [workspaceContext],
            openSessionIDs: [])

        #expect(try #require(presentation.items.first { $0.label == "Codex busy" }).detail == "reviewing PR 493")
        #expect(try #require(presentation.items.first { $0.label == "Codex quiet" }).detail == "codex --model gpt-5.6-sol")
    }

    @Test func globalScopeListsEveryWorkspaceInOrderAndExcludesOpenSessionsFromEither() {
        let workspaceA = richWorkspace(id: "workspace-1")
        let workspaceB = richWorkspace(id: "workspace-2")
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace-1", newTerminalOverview: context(for: workspaceA).overview,
            scopedWorkspaces: [context(for: workspaceA), context(for: workspaceB)],
            openSessionIDs: ["session-web-workspace-1", "session-agent-workspace-2"])

        // Both workspaces' targets appear in scope order; the open web (workspace-1) and agent
        // (workspace-2) sessions drop from their respective workspaces.
        #expect(
            presentation.items.map(\.id) == [
                "picker:new", "picker:workspace-1::2", "picker:workspace-1::3", "picker:workspace-1::4", "picker:workspace-2::1",
                "picker:workspace-2::2", "picker:workspace-2::4",
            ])
        #expect(presentation.items.map(\.label) == ["New terminal session", "api", "claude", "shell", "web", "api", "shell"])
    }
}
