import Testing
import spacesclientcore
import spacesdevicecore
import workspacecore

@testable import spacesui

@Suite struct PinnedThreadSidebarTests {
    /// Two running agents and one not-running pin. "reviewer" is a running pinned row, "design" is a
    /// not-running pin, "claude" is an ordinary agent row; pin order is reviewer then design.
    private func workspace(pinUnavailableReason: SpacesDeviceAgentPinUnavailableReason? = nil) -> SpacesDeviceWorkspaceSummary {
        let config = SpacesDeviceWorkspaceConfig(
            processes: [SpacesDeviceProcessTemplate(id: "tpl-api", name: "api", command: "npm run api")],
            resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "docs", url: "http://localhost:3000")])
        return SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/project-feature",
            isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: true, config: config,
            processRows: [
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-api", workspaceID: "workspace", name: "api", command: "npm run api", templateID: "tpl-api", processID: nil,
                    sessionID: nil, runState: .notStarted, canRun: true, canStop: false, canRestart: false)
            ],
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-1", workspaceID: "workspace", name: "claude", command: "claude", agentID: "agent-1", sessionID: "session-1",
                    runState: .running, activityState: .idle, brief: nil, briefUpdatedAt: nil, canStop: true,
                    pinUnavailableReason: pinUnavailableReason),
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-2", workspaceID: "workspace", name: "reviewer", command: "claude", agentID: "agent-2", sessionID: "session-2",
                    runState: .running, activityState: .spinning, brief: "# Reviewing", briefUpdatedAt: "2026-11-01T00:00:00Z", canStop: true,
                    pinID: "pin-1"),
            ],
            pinnedThreads: [
                SpacesDeviceWorkspacePinnedThread(id: "pin-1", workspaceID: "workspace", name: "reviewer", agentRowID: "agent:agent-2"),
                SpacesDeviceWorkspacePinnedThread(
                    id: "pin-2", workspaceID: "workspace", name: "design", agentRowID: nil, brief: "# Design notes",
                    briefUpdatedAt: "2026-11-01T00:00:00Z"),
            ],
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "row-shell", workspaceID: "workspace", title: "shell", workingDirectory: "/tmp/project-feature", sessionID: "session-shell",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
    }

    private func items(_ workspace: SpacesDeviceWorkspaceSummary) -> [SidebarRuntimeTargetItem] {
        AppKitController.sidebarRuntimeTargetItems(detail: SpacesDeviceWorkspaceDetailViewModel(workspace: workspace), browserSessions: [])
    }

    @Test func pinnedRowsComeFirstAmongAgentsAndTakeNumberedSlots() throws {
        let items = items(workspace())
        // api(1), then the coding-agent family in agentEntries order: running pin, not-running pin, unpinned
        // agent; the ad hoc terminal follows.
        #expect(items.map(\.key) == ["missing:api", "agent:agent-2", "pin:pin-2", "agent:agent-1", "terminal:session-shell"])
        #expect(items.map(\.shortcutIndex) == [1, 2, 3, 4, 5])
    }

    @Test func aNotRunningPinIsAnInactiveRowWithItsBrief() throws {
        let pin = try #require(items(workspace()).first { $0.kind == .pinnedThread })
        #expect(pin.title == "design")
        #expect(pin.pinID == "pin-2")
        #expect(pin.runState == .notStarted)
        #expect(pin.sessionID == nil)
        #expect(!pin.canStop)
        #expect(pin.hasBrief)
        #expect(pin.attentionStatus == .inactive)
    }

    @Test func aRunningPinnedRowCarriesItsPinAndStaysAnAgentRow() throws {
        let row = try #require(items(workspace()).first { $0.key == "agent:agent-2" })
        #expect(row.kind == .agent)
        #expect(row.pinID == "pin-1")
        #expect(row.attentionStatus == .working)
    }

    /// Slots: docs browser(1), api(2), running pinned row(3), not-running pin(4), unpinned agent(5), shell(6).
    @Test func numberedShortcutsResumeANotRunningPin() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [workspace()], sessions: [])
        #expect(
            AppKitController.deviceWindowShortcutResolution(index: 4, selectedWorkspaceID: "workspace", overview: overview)
                == .resumePinnedThread(workspaceID: "workspace", pinID: "pin-2"))
        // The running pinned row still focuses its terminal.
        guard
            case .openTerminal(let request) = AppKitController.deviceWindowShortcutResolution(
                index: 3, selectedWorkspaceID: "workspace", overview: overview)
        else {
            Issue.record("a running pinned row opens its terminal")
            return
        }
        #expect(request.sessionID == "session-2")
    }

    @Test func aNotRunningPinIsNotAWindowCycleTarget() {
        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: workspace())
        let targets = WindowFocusController.cycleWindowTargets(
            detail: detail, browserSessions: [], openTerminalSessionIDs: ["session-1", "session-2"])
        #expect(targets.allSatisfy { $0.kind != .pinnedThread })
        #expect(targets.count == 2)
    }

    @Test func aFocusRequestForAPinResumesIt() {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [workspace()], sessions: [])
        #expect(
            WindowFocusController.windowFocusResolution(for: .pinnedThread(workspaceID: "workspace", pinID: "pin-2"), overview: overview)
                == .resumePinnedThread(workspaceID: "workspace", pinID: "pin-2"))
    }

    @Test func theCommandPaletteListsANotRunningPinAndChoosingItResumes() throws {
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [workspace()], sessions: [])
        let palette = CommandPaletteController.deviceCommandPaletteWorkspaceItems(from: overview)
        let pin = try #require(palette.first { $0.kind == .pinnedThread })
        #expect(pin.label == "design")
        let request = try #require(pin.focusRequest)
        #expect(
            WindowFocusController.windowFocusResolution(for: request, overview: overview)
                == .resumePinnedThread(workspaceID: "workspace", pinID: "pin-2"))
    }

    @Test func renamingAPinnedRowRenamesThePinAndAnEmptyNameIsDiscarded() throws {
        let items = items(workspace())
        let notRunning = try #require(items.first { $0.kind == .pinnedThread })
        let running = try #require(items.first { $0.key == "agent:agent-2" })
        let unpinned = try #require(items.first { $0.key == "agent:agent-1" })
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: notRunning, newTitle: "Design v2") == .pinnedThread(pinID: "pin-2"))
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: running, newTitle: "Reviewer 2") == .pinnedThread(pinID: "pin-1"))
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: notRunning, newTitle: "  ") == .discard)
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: running, newTitle: "") == .discard)
        // An unpinned agent still clears back to its default name on an empty rename.
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: unpinned, newTitle: " ") == .agentSession(agentID: "agent-1"))
    }

    @Test func menuOffersPinOnUnpinnedAgentsAndUnpinOnPinnedRows() throws {
        let items = items(workspace())
        let notRunning = try #require(items.first { $0.kind == .pinnedThread })
        let running = try #require(items.first { $0.key == "agent:agent-2" })
        let unpinned = try #require(items.first { $0.key == "agent:agent-1" })
        let process = try #require(items.first { $0.kind == .missingConfiguredProcess })
        #expect(SidebarController.pinMenuState(item: unpinned) == .pin(unavailableReason: nil))
        #expect(SidebarController.pinMenuState(item: running) == .unpin)
        #expect(SidebarController.pinMenuState(item: notRunning) == .unpin)
        #expect(SidebarController.pinMenuState(item: process) == nil)
    }

    @Test func pinIsDisabledWithTheDaemonsReasonWhenTheRowCannotBePinned() throws {
        for reason in [SpacesDeviceAgentPinUnavailableReason.noConversation, .oneShotRun, .conversationPinned] {
            let unpinned = try #require(items(workspace(pinUnavailableReason: reason)).first { $0.key == "agent:agent-1" })
            #expect(SidebarController.pinMenuState(item: unpinned) == .pin(unavailableReason: reason))
        }
    }

    private func sessionSummary(id: String) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: "reviewer", workingDirectory: "/tmp/project-feature", shell: "/bin/zsh", command: "claude --resume abc", state: .running,
            backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678, workspaceID: "workspace",
            workspaceTitle: "Workspace", projectID: "project", projectName: "Project", createdAt: "2026-11-01T00:00:00Z",
            updatedAt: "2026-11-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: .init())
    }

    @Test func resumingAPinOpensTheLaunchedSessionEvenWhenTheOverviewNoLongerListsIt() throws {
        // The resumed agent exited at once, so the reconciler already dropped it from the overview.
        let response = SpacesDeviceAPIResponse(
            ok: true, message: "Resumed pinned thread.",
            result: .mutation(.init(sessionID: "session-new", launchedTerminalSession: sessionSummary(id: "session-new"))))
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspace()], sessions: [])
        let request = try #require(
            AppKitController.terminalOpenRequest(fromMutationResponse: response, workspaceID: "workspace", deviceID: "device-1", overview: overview))
        #expect(request.sessionID == "session-new")
        #expect(request.deviceID == "device-1")
        #expect(request.command == "claude --resume abc")
    }

    @Test func resumingAPinThatIsAlreadyRunningResolvesItsSessionThroughTheOverview() throws {
        let response = SpacesDeviceAPIResponse(ok: true, message: "Resumed pinned thread.", result: .mutation(.init(sessionID: "session-2")))
        let overview = SpacesDeviceOverviewPayload(workspaces: [workspace()], sessions: [sessionSummary(id: "session-2")])
        let request = try #require(
            AppKitController.terminalOpenRequest(fromMutationResponse: response, workspaceID: "workspace", deviceID: "device-1", overview: overview))
        #expect(request.sessionID == "session-2")
        let withoutSession = SpacesDeviceOverviewPayload(workspaces: [workspace()], sessions: [])
        #expect(
            AppKitController.terminalOpenRequest(
                fromMutationResponse: response, workspaceID: "workspace", deviceID: "device-1", overview: withoutSession) == nil)
    }
}
