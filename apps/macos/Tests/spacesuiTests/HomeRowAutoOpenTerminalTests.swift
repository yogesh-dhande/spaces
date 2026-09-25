import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import spacesterminalui
import spacestestsupport

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Covers the home row's auto-open (`AppKitController.autoOpenHomeTerminalIfNeeded`, reached from
    /// `showWorkspaceDetail`): selecting `~` lands the user in a terminal, and never disturbs panes they
    /// arranged or closed.
    ///
    /// Drives the real chokepoint with a real `AppKitController`, built the way
    /// `AppKitControllerOwnerReclaimShortcutTests` builds one (a fabricated lease/profile over a throwaway
    /// temp directory). Two seams keep the daemon out of it: a stub pane content controller per session,
    /// so a pane opens without dialing a session stream, and
    /// `createWorkspaceTerminalSessionOverrideForTesting`, which stands in for the session creation the
    /// `New terminal` path would have asked the daemon for, and which a test holds open to stand in for a
    /// device that takes its time. Nests under
    /// `ProcessProfileEnvironmentSuites` because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class HomeRowAutoOpenTerminalTests {
        private static let homeProjectID = "project-home"
        private static let homeWorkspaceID = "workspace-home"
        private static let homeDirectory = "/tmp/home"
        private static let standardProjectID = "project-1"
        private static let standardWorkspaceID = "workspace-1"

        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        private func makeController() -> AppKitController {
            let profile = SpacesProfile(
                source: .explicitDatabasePath, databasePath: root.appendingPathComponent("spaces.db").path, rootDirectory: root.path,
                isInstalledProfile: false, runtimeDirectory: root.appendingPathComponent("runtime").path,
                ipcNotificationObject: "com.spaces.test.\(UUID().uuidString)", developmentContext: nil, branchSlug: nil, worktreeHash: nil)
            let owner = SpacesProcessLeaseOwner(
                pid: ProcessInfo.processInfo.processIdentifier, executablePath: "/tmp/spaces-test", profileRoot: root.path, token: UUID().uuidString,
                acquiredAt: "2026-01-01T00:00:00Z")
            let lease = SpacesProcessLease(
                owner: owner, leaseDirectoryPath: root.appendingPathComponent("app-owner-lease").path, metadataPath: "unused", fileManager: .default)
            let context = SpacesAppLaunchContext(profile: profile, appOwnerLease: lease, desktopControlState: .passive(owner))
            return AppKitController(launchContext: context)
        }

        private func localDevice() -> SpacesPairedDeviceRecord {
            SpacesPairedDeviceRecord(
                id: SpacesPairedDeviceRecord.localDeviceID, name: "This Mac", platform: "macos", hosts: ["127.0.0.1"], port: 47847,
                certificateFingerprint: "fingerprint", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        /// The device as its daemon reports it: the home project with its single workspace, one ad hoc
        /// terminal row per entry in `terminals`, plus an ordinary git project whose workspace stands in
        /// for every row that is not the home row.
        private func overview(terminals: [(sessionID: String, runState: SpacesDeviceRunState)]) -> SpacesDeviceOverviewPayload {
            let homeWorkspace = SpacesDeviceWorkspaceSummary(
                id: Self.homeWorkspaceID, projectID: Self.homeProjectID, projectName: ProjectKind.homeProjectName, projectKind: .home, branch: nil,
                baseBranch: nil, dir: Self.homeDirectory, isRunning: terminals.contains { $0.runState == .running }, isHidden: false, isDefault: true,
                hasTrackedRuntimeIndicators: terminals.contains { $0.runState == .running },
                terminalRows: terminals.map { terminal in
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "row-\(terminal.sessionID)", workspaceID: Self.homeWorkspaceID, title: terminal.sessionID,
                        workingDirectory: Self.homeDirectory, sessionID: terminal.sessionID, runState: terminal.runState, canOpenTerminal: true,
                        canStop: terminal.runState == .running)
                })
            let standardWorkspace = SpacesDeviceWorkspaceSummary(
                id: Self.standardWorkspaceID, projectID: Self.standardProjectID, projectName: "Project", branch: "feature", baseBranch: "main",
                dir: "/tmp/project-feature", isRunning: false, isHidden: false, isDefault: true, hasTrackedRuntimeIndicators: false)
            return SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(
                        id: Self.homeProjectID, name: ProjectKind.homeProjectName, dir: Self.homeDirectory, isGitRepo: false, defaultBranch: nil,
                        kind: .home),
                    SpacesDeviceProjectSummary(
                        id: Self.standardProjectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main"),
                ], workspaces: [homeWorkspace, standardWorkspace],
                sessions: terminals.map { terminal in
                    SpacesDeviceTerminalSessionSummary(
                        id: terminal.sessionID, title: terminal.sessionID, workingDirectory: Self.homeDirectory, shell: "/bin/zsh",
                        command: "/bin/zsh", state: terminal.runState == .running ? .running : .exited, backend: .ghosttyEmbedded,
                        lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678, workspaceID: Self.homeWorkspaceID,
                        workspaceTitle: ProjectKind.homeProjectName, projectID: Self.homeProjectID, projectName: ProjectKind.homeProjectName,
                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: true, isSubscriptionAvailable: true,
                        attachmentSnapshot: .init(), rowKind: .liveSession)
                }, retainedTerminalSessionIDs: terminals.map(\.sessionID))
        }

        // `loadState` defaults to the section's normal loading/loaded split (nil overview means the
        // device hasn't reported yet); a caller that wants to drive `deviceAcceptsDaemonActions` to
        // false with an overview already in hand (an unreachable device whose rows stay listed, per
        // `deviceAcceptsDaemonActions`'s doc comment) passes `.offline` explicitly.
        private func section(overview: SpacesDeviceOverviewPayload?, deviceID: String, loadState: AppKitController.SidebarDeviceLoadState? = nil)
            -> AppKitController.DeviceSection
        {
            let mapped = AppKitController.deviceSidebarData(from: overview ?? self.overview(terminals: []), deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: loadState ?? (overview == nil ? .loading : .loaded),
                device: localDevice(), projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview)
        }

        private func snapshot(overview: SpacesDeviceOverviewPayload, deviceID: String) -> AppKitController.SidebarDataSnapshot {
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.SidebarDataSnapshot(
                config: AppConfig(portRange: .default),
                local: AppKitController.LocalDeviceSidebarSnapshot(
                    projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                    workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, alertsGroups: [], localDeviceID: deviceID,
                    localDeviceName: "This Mac", localPairedDevice: localDevice(), localDeviceOverview: overview, localDaemonStatus: .testStatus,
                    localCompatibility: .compatible, localOfflineMessage: nil))
        }

        /// A controller holding `overview`, with every seam a test needs in place: a stub content
        /// controller per session (so a pane opens without a live terminal behind it), the panel's window
        /// activation stubbed out (a unit test process must never call `NSApp.activate`), and any sidebar
        /// reload the presentation asks for answered with this same overview.
        private func makeController(
            overview: SpacesDeviceOverviewPayload, sectionOverview: SpacesDeviceOverviewPayload?,
            sectionLoadState: AppKitController.SidebarDeviceLoadState? = nil
        ) -> AppKitController {
            let controller = makeController()
            let deviceID = controller.deviceModel.localDeviceID
            controller.deviceModel.deviceSections = [section(overview: sectionOverview, deviceID: deviceID, loadState: sectionLoadState)]
            controller.rebuildFlatSidebarData()
            installPaneContentStubs(controller, sessions: overview.sessions)
            controller.showPanelScopeOverrideForTesting = { _ in }
            let reloaded = snapshot(overview: overview, deviceID: deviceID)
            controller.sidebar.loadSnapshotOverrideForTesting = { .success(reloaded) }
            return controller
        }

        /// Gives each session a pane content stub, so a pane opens without dialing a session stream.
        /// Closing a pane disposes its content controller along with the pane, so a test that opens the
        /// same session a second time installs the stubs again first; without that, the second open builds
        /// the real daemon-backed content this suite has nothing behind.
        private func installPaneContentStubs(_ controller: AppKitController, sessions: [SpacesDeviceTerminalSessionSummary]) {
            let deviceID = controller.deviceModel.localDeviceID
            for session in sessions {
                controller.panelCoordinator.installContentControllerForTesting(
                    HomeRowTerminalPaneContentStub(
                        descriptor: .terminalSession(deviceID: deviceID, sessionID: session.id), workspaceID: Self.homeWorkspaceID,
                        sessionID: session.id), sessionID: session.id)
            }
        }

        /// The open request a finished creation resolves with, standing in for the session the daemon
        /// would have made, with a pane content stub behind it so its pane can open without a live
        /// terminal.
        private func createdSession(_ controller: AppKitController, sessionID: String) -> AppKitController.DeviceTerminalOpenRequest {
            controller.panelCoordinator.installContentControllerForTesting(
                HomeRowTerminalPaneContentStub(
                    descriptor: .terminalSession(deviceID: controller.deviceModel.localDeviceID, sessionID: sessionID),
                    workspaceID: Self.homeWorkspaceID, sessionID: sessionID), sessionID: sessionID)
            return AppKitController.DeviceTerminalOpenRequest(
                workspaceID: Self.homeWorkspaceID, sessionID: sessionID, title: sessionID, workingDirectory: Self.homeDirectory, kind: .shell)
        }

        private func homePanelScope(_ controller: AppKitController) -> PanelScope {
            .workspace(deviceID: controller.deviceModel.localDeviceID, workspaceID: Self.homeWorkspaceID)
        }

        /// The user landing on a row, in the order the sidebar's own selection handler writes it: the
        /// persisted active workspace, then the selection, then the presentation it drives.
        private func selectWorkspace(_ controller: AppKitController, id: String) throws {
            let (project, workspace) = try #require(controller.findWorkspace(id: id))
            controller.selectedProjectID = project.id
            AppKitController.setClientActiveWorkspaceID(workspace.id)
            controller.selectedWorkspaceID = workspace.id
            controller.showWorkspaceDetail(project: project, workspace: workspace, presentation: .userNavigation)
        }

        /// A presentation that is not a selection: the reconcile pass `refreshSelection` runs on every
        /// overview tick re-presents the selected workspace without the selection ever moving.
        private func refreshSelectedWorkspace(_ controller: AppKitController, id: String) throws {
            let (project, workspace) = try #require(controller.findWorkspace(id: id))
            controller.showWorkspaceDetail(project: project, workspace: workspace, presentation: .backgroundRefresh)
        }

        /// The user leaving the selected row for the Alerts pane: it takes over the detail area and
        /// clears the sidebar selection, while the workspace-detail presentation history stays pointing at
        /// the row they left, which is the distinction these tests care about. Only that state is set up
        /// here; the pane's own render is left to `AlertsController`, since it draws live alert rows
        /// against the client database and this suite stands up neither.
        private func showAlerts(_ controller: AppKitController) {
            controller.presentDetailPane(.alerts, presentation: .userNavigation)
            controller.selectedProjectID = nil
            controller.selectedWorkspaceID = nil
        }

        /// Lets the auto-open's own task (a pane open runs asynchronously, as the sidebar row click it
        /// reuses does) and any reload it triggered run to completion.
        private func settle() async { for _ in 0..<10 { await Task.yield() } }

        /// Rule 1: the row is a terminal-only row, so selecting it with nothing running starts the
        /// terminal the user came for, exactly as the `New terminal` shortcut would.
        @Test func selectingTheHomeRowWithNothingRunningStartsOneTerminal() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(created == [Self.homeWorkspaceID], "selecting the home row with no session running must start exactly one terminal in it")
        }

        /// Rule 1 is a precondition, not an override: selecting the row never asked for a terminal to be
        /// created, so an unreachable device just leaves the panel empty instead of raising the
        /// unavailable-device alert the explicit `New terminal` affordance shows for a click the user
        /// actually made.
        @Test func selectingTheHomeRowOnAnUnreachableDeviceStartsNothing() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload, sectionLoadState: .offline("unreachable"))
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(created.isEmpty, "an unreachable device must not have a terminal auto-created against it")
            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "the panel must stay empty")
        }

        /// Rule 2: the one session that is already running is what the user means, so its pane opens
        /// instead of a second session being started.
        @Test func selectingTheHomeRowWithOneRunningSessionOpensThatSessionsPane() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(controller.panelCoordinator.placement(forSessionID: "session-1") != nil, "the running session's pane must open in the home panel")
            #expect(created.isEmpty, "a session was already running, so nothing may be created")
        }

        /// Rule 3: a panel that already holds a pane is the arrangement the user has, whichever session
        /// that pane shows.
        @Test func selectingTheHomeRowLeavesAPanelThatAlreadyHoldsAPaneAlone() async throws {
            let payload = overview(terminals: [(sessionID: "session-live", runState: .running), (sessionID: "session-ended", runState: .exited)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }
            controller.panelCoordinator.openSessionInNewTab(
                AppKitController.DeviceTerminalOpenRequest(
                    workspaceID: Self.homeWorkspaceID, sessionID: "session-ended", title: "session-ended", workingDirectory: Self.homeDirectory,
                    kind: .shell))

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).tabs.count == 1, "the panel must be left exactly as it was")
            #expect(controller.panelCoordinator.placement(forSessionID: "session-live") == nil, "no pane may open over the panel the user arranged")
            #expect(created.isEmpty, "a panel that already holds a pane must not start a terminal")
        }

        /// Rule 3: with several sessions running and no pane open, the user closed those panes on purpose
        /// and picking one of them to reopen would be a guess.
        @Test func selectingTheHomeRowWithTwoRunningSessionsOpensNothing() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running), (sessionID: "session-2", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "two running sessions must leave the panel empty")
            #expect(created.isEmpty, "two running sessions must not start a third")
        }

        /// The auto-open follows a selection change, not a presentation: the overview ticks that
        /// re-present the selected workspace every few seconds must not reopen a pane the user closed.
        @Test func aBackgroundRefreshOfTheSelectedHomeRowDoesNotOpenAnything() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()
            #expect(controller.panelCoordinator.placement(forSessionID: "session-1") != nil, "precondition: the selection opened the session's pane")
            controller.panelCoordinator.closeTerminalPanes(workspaceID: Self.homeWorkspaceID)
            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "precondition: the user closed the pane")

            try refreshSelectedWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(
                controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty,
                "re-presenting the row the user is already on must leave the pane they closed closed")
            #expect(created.isEmpty, "re-presenting the selected row must not start a second terminal")
        }

        /// Only the home row auto-opens: an ordinary workspace with nothing running keeps its empty
        /// panel, which is the empty state's job to explain.
        @Test func selectingAStandardWorkspaceOpensNothing() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }

            try selectWorkspace(controller, id: Self.standardWorkspaceID)
            await settle()

            let scope = PanelScope.workspace(deviceID: controller.deviceModel.localDeviceID, workspaceID: Self.standardWorkspaceID)
            #expect(controller.panelCoordinator.layout(for: scope).isEmpty, "a standard workspace's panel stays empty")
            #expect(created.isEmpty, "a standard workspace must not start a terminal on selection")
        }

        /// A selection landing before its device's overview has nothing to decide from, so it waits: the
        /// decision runs once, when the overview for that still-selected workspace arrives.
        @Test func aSelectionThatLandsBeforeTheOverviewAutoOpensOnceItArrives() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: nil)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            #expect(
                controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty,
                "a selection with no overview behind it must decide nothing yet")
            #expect(created.isEmpty, "a selection with no overview behind it must start nothing yet")

            controller.deviceModel.deviceSections = [section(overview: payload, deviceID: controller.deviceModel.localDeviceID)]
            controller.rebuildFlatSidebarData()
            try refreshSelectedWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(
                controller.panelCoordinator.placement(forSessionID: "session-1") != nil,
                "the arriving overview must complete the waiting selection's auto-open")
            #expect(
                controller.panelCoordinator.layout(for: homePanelScope(controller)).tabs.count == 1,
                "the waiting selection must auto-open exactly once")
            #expect(created.isEmpty, "a session was already running, so nothing may be created")
        }

        /// Alerts and Automations clear the sidebar selection without selecting another row, so coming
        /// back to `~` selects it again and lands the user in a terminal again, exactly as arriving from
        /// any other row would.
        @Test func returningToTheHomeRowFromAlertsAutoOpensAgain() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()
            #expect(controller.panelCoordinator.placement(forSessionID: "session-1") != nil, "precondition: the selection opened the session's pane")
            controller.panelCoordinator.closeTerminalPanes(workspaceID: Self.homeWorkspaceID)
            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "precondition: the user closed the pane")
            installPaneContentStubs(controller, sessions: payload.sessions)

            showAlerts(controller)
            #expect(controller.selectedWorkspaceID == nil, "precondition: the Alerts pane holds no workspace selection")
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(
                controller.panelCoordinator.placement(forSessionID: "session-1") != nil,
                "selecting the row again after a detour through Alerts must land the user in its terminal again")
            #expect(created.isEmpty, "a session was already running, so nothing may be created")
        }

        /// The auto-open follows the selection landing on the row, so the row the user is already on has
        /// nothing to land on: selecting it again leaves the panel they arranged alone.
        @Test func reselectingTheHomeRowAlreadySelectedOpensNothing() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()
            #expect(controller.panelCoordinator.placement(forSessionID: "session-1") != nil, "precondition: the selection opened the session's pane")
            controller.panelCoordinator.closeTerminalPanes(workspaceID: Self.homeWorkspaceID)
            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "precondition: the user closed the pane")

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(
                controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty,
                "re-selecting the row the user is already on must leave the pane they closed closed")
            #expect(created.isEmpty, "re-selecting the already-selected row must not start a second terminal")
        }

        /// Rule 2 is gated on the device exactly as rule 1 is: an unreachable device's rows keep listing
        /// the session its last overview reported, and opening that session's pane would have to attach it
        /// on a device that cannot answer. Selecting the row is not a request to do that, so it raises
        /// nothing, the same as a row click on an unreachable device does not.
        @Test func selectingTheHomeRowWithOneRunningSessionOnAnUnreachableDeviceOpensNothing() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload, sectionLoadState: .offline("unreachable"))
            var created: [String] = []
            controller.createWorkspaceTerminalSessionOverrideForTesting = { workspaceID, _ in created.append(workspaceID) }
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(
                controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty,
                "an unreachable device's cached session must not have its pane opened against it")
            #expect(created.isEmpty, "an unreachable device must not have a terminal auto-created against it")
            #expect(errors.isEmpty, "selecting a row must not raise the unavailable-device alert")
        }

        /// The creation the selection started can outlive the selection that started it: a device that
        /// takes its time finishes it long after the user has moved to another row, and the terminal they
        /// never asked for must not pull them back there.
        @Test func aHomeRowTerminalThatArrivesAfterTheUserMovesOnDoesNotPullThemBack() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var pendingCreation: ((AppKitController.DeviceTerminalOpenRequest?) -> Void)?
            controller.createWorkspaceTerminalSessionOverrideForTesting = { _, completion in pendingCreation = completion }
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()
            let finishCreation = try #require(pendingCreation, "precondition: selecting the home row started a terminal")

            try selectWorkspace(controller, id: Self.standardWorkspaceID)
            await settle()
            finishCreation(createdSession(controller, sessionID: "session-late"))
            await settle()

            #expect(controller.selectedWorkspaceID == Self.standardWorkspaceID, "the user's own navigation must keep the selection")
            #expect(
                controller.panelCoordinator.placement(forSessionID: "session-late") == nil,
                "a terminal that arrives after the user moved on must not open its pane")
            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "the home panel must stay as the user left it")
        }

        /// The same creation finishing while the user is still on the row is what they are waiting for, so
        /// it lands as a pane there.
        @Test func aHomeRowTerminalThatArrivesWhileTheRowIsStillSelectedOpensItsPane() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var pendingCreation: ((AppKitController.DeviceTerminalOpenRequest?) -> Void)?
            controller.createWorkspaceTerminalSessionOverrideForTesting = { _, completion in pendingCreation = completion }
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()
            let finishCreation = try #require(pendingCreation, "precondition: selecting the home row started a terminal")

            finishCreation(createdSession(controller, sessionID: "session-new"))
            await settle()

            #expect(
                controller.panelCoordinator.placement(forSessionID: "session-new") != nil,
                "a terminal that arrives while its row is still selected must open as a pane there")
        }

        /// The device is checked when the selection decides to auto-open, and can drop while the creation
        /// it started is still in flight. Driving the creation itself against a device that cannot be
        /// reached is that same refusal: the row never asked for the terminal, so the refusal is logged and
        /// the user is left alone, whichever row they are on by the time it lands.
        @Test func anImplicitHomeRowCreationDoesNotRaiseItsDeviceRefusal() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload, sectionLoadState: .offline("unreachable"))
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }
            var refusals = 0

            controller.terminalPanes.createTerminalSessionForPane(workspaceID: Self.homeWorkspaceID, route: .homeRowSelection) { request in
                if request == nil { refusals += 1 }
            }
            await settle()

            #expect(refusals == 1, "the creation must still refuse, and tell its caller it made nothing")
            #expect(errors.isEmpty, "a terminal the user never asked for must not raise its failure")
        }

        /// The same refusal for a terminal the user asked for keeps its alert: this is the `New terminal`
        /// affordance telling them why nothing came up.
        @Test func anExplicitCreationRaisesItsDeviceRefusal() async throws {
            let payload = overview(terminals: [])
            let controller = makeController(overview: payload, sectionOverview: payload, sectionLoadState: .offline("unreachable"))
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }

            controller.terminalPanes.createTerminalSessionForPane(workspaceID: Self.homeWorkspaceID, route: .button) { _ in }
            await settle()

            #expect(errors.count == 1, "a terminal the user asked for is owed the reason it did not come up")
        }

        /// Rule 2's open runs against the device too, and the device can drop after the selection admitted
        /// it. The open is abandoned where the install would have refused with a modal, so the panel is left
        /// empty and nothing is raised.
        @Test func anImplicitHomeRowPaneOpenDoesNotRaiseItsDeviceRefusal() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload, sectionLoadState: .offline("unreachable"))
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }
            let key = try #require(controller.sidebarRuntimeTargetItems(workspaceID: Self.homeWorkspaceID).first?.key)

            controller.focusSidebarRuntimeTarget(workspaceID: Self.homeWorkspaceID, key: key, route: .homeRowSelection)
            await settle()

            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "the panel must stay empty")
            #expect(errors.isEmpty, "an open the user never asked for must not raise the unavailable-device alert")
        }

        /// Clicking the same row is a click the user made, so its refusal still names the device.
        @Test func anExplicitPaneOpenRaisesItsDeviceRefusal() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload, sectionLoadState: .offline("unreachable"))
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }
            let key = try #require(controller.sidebarRuntimeTargetItems(workspaceID: Self.homeWorkspaceID).first?.key)

            controller.focusSidebarRuntimeTarget(workspaceID: Self.homeWorkspaceID, key: key)
            await settle()

            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "the panel must stay empty")
            #expect(errors.count == 1, "a row click is owed the reason its pane did not open")
        }

        /// Rule 2's open runs asynchronously, exactly as the sidebar row click it reuses does, so the user
        /// can leave the row before it resumes. The terminal they never asked for must not pull them back:
        /// no pane in the row they left, the row they went to still selected, and the active workspace
        /// their own navigation persisted left alone.
        @Test func aHomeRowPaneOpenThatResumesAfterTheUserMovesOnDoesNotPullThemBack() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            // Nothing has yielded to the open the selection started, so it is still suspended where the
            // user moving to another row leaves it.
            try selectWorkspace(controller, id: Self.standardWorkspaceID)
            await settle()

            #expect(controller.selectedWorkspaceID == Self.standardWorkspaceID, "the user's own navigation must keep the selection")
            #expect(
                controller.panelCoordinator.placement(forSessionID: "session-1") == nil,
                "an open that resumes after the user moved on must not open its pane")
            #expect(controller.panelCoordinator.layout(for: homePanelScope(controller)).isEmpty, "the home panel must stay as the user left it")
            #expect(
                controller.clientActiveWorkspaceID() == Self.standardWorkspaceID,
                "an abandoned open must not take the persisted active workspace back to the row it started on")
            #expect(errors.isEmpty, "an open nobody asked for must abandon silently")
        }

        /// The control for the case above: the same open resuming while the row is still selected is what
        /// the user is waiting for, so it lands as a pane there.
        @Test func aHomeRowPaneOpenThatResumesWhileTheRowIsStillSelectedOpensItsPane() async throws {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            var errors: [String] = []
            controller.showErrorOverrideForTesting = { errors.append("\($0)") }

            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()

            #expect(controller.selectedWorkspaceID == Self.homeWorkspaceID, "precondition: the user is still on the row they selected")
            #expect(
                controller.panelCoordinator.placement(forSessionID: "session-1") != nil,
                "an open that resumes while its row is still selected must open its pane there")
            #expect(controller.clientActiveWorkspaceID() == Self.homeWorkspaceID, "the row the open presents is the active workspace")
            #expect(errors.isEmpty, "a pane that opened must raise nothing")
        }

        /// The open suspends one last time after its pane is up, and reporting a landing is itself a
        /// presentation: the caller selects the target's workspace for one
        /// (`executeWindowFocusResolution`'s `.openTerminal` case). The user can leave the row during that
        /// suspension too, so an open they left reports none, and the sidebar stays where they went.
        @Test func aHomeRowPaneOpenThatLosesItsRowAtTheLastSuspensionReportsNoLanding() async throws {
            let controller = try await controllerOnTheHomeRowLeavingItAtTheLastSuspension()

            let landed = await controller.windowFocus.executeWindowFocusResolution(
                .openTerminal(homeSessionOpenRequest(sessionID: "session-1")), route: .homeRowSelection)

            #expect(
                controller.selectedWorkspaceID == Self.standardWorkspaceID,
                "precondition: the open reached its last suspension and the user's own navigation moved the selection there")
            #expect(!landed, "an open nobody asked for, whose row the user left, must report no landing for its caller to present")
        }

        /// The control for the case above: a terminal the user asked for lands where they asked for it
        /// however long it took, so the same suspension-time move leaves its landing intact and the caller
        /// brings them to the row.
        @Test func anExplicitPaneOpenThatLosesItsRowAtTheLastSuspensionStillLands() async throws {
            let controller = try await controllerOnTheHomeRowLeavingItAtTheLastSuspension()

            let landed = await controller.windowFocus.executeWindowFocusResolution(.openTerminal(homeSessionOpenRequest(sessionID: "session-1")))

            #expect(
                controller.selectedWorkspaceID == Self.standardWorkspaceID,
                "precondition: the open reached its last suspension and the user's own navigation moved the selection there")
            #expect(landed, "a terminal the user asked for must land whichever row they are on by the time it opens")
        }

        /// A controller sitting on `~` with `session-1`'s pane open, whose next open of that pane leaves
        /// the row at its last suspension: the pane's stub moves the selection when the open reclaims
        /// ownership, which is the last thing it does before the yield it reports its landing after.
        private func controllerOnTheHomeRowLeavingItAtTheLastSuspension() async throws -> AppKitController {
            let payload = overview(terminals: [(sessionID: "session-1", runState: .running)])
            let controller = makeController(overview: payload, sectionOverview: payload)
            try selectWorkspace(controller, id: Self.homeWorkspaceID)
            await settle()
            #expect(controller.panelCoordinator.placement(forSessionID: "session-1") != nil, "precondition: the selection opened the session's pane")
            let content = try #require(controller.panelCoordinator.content(forSessionID: "session-1") as? HomeRowTerminalPaneContentStub)
            content.onRequestOwnership = { [weak self, weak controller] in
                guard let self, let controller, controller.selectedWorkspaceID != Self.standardWorkspaceID else { return }
                try? self.selectWorkspace(controller, id: Self.standardWorkspaceID)
            }
            return controller
        }

        /// The request a home-row session's row resolves to, for a test driving the open directly.
        private func homeSessionOpenRequest(sessionID: String) -> AppKitController.DeviceTerminalOpenRequest {
            AppKitController.DeviceTerminalOpenRequest(
                workspaceID: Self.homeWorkspaceID, sessionID: sessionID, title: sessionID, workingDirectory: Self.homeDirectory, kind: .shell)
        }
    }
}

/// A pane's content without a terminal behind it: `HomeRowAutoOpenTerminalTests` drives real pane opens,
/// and every one of them would otherwise build a controller that dials the daemon for its session stream.
/// Every member is a trivial stub, since the tests assert where panes land, never what they render.
@MainActor private final class HomeRowTerminalPaneContentStub: TerminalPaneContentHosting {
    let descriptor: PaneContentDescriptor
    let workspaceID: String
    let sessionID: String
    var holdsOwnerAttachedSurface = false

    var onTitleChanged: ((String) -> Void)?
    var displayTitle: String { "stub" }
    lazy var contentView: NSView = NSView()

    init(descriptor: PaneContentDescriptor, workspaceID: String, sessionID: String) {
        self.descriptor = descriptor
        self.workspaceID = workspaceID
        self.sessionID = sessionID
    }

    func activate(focus: Bool) {}
    func deactivate() {}
    func close() {}
    func closeForSessionTermination() {}

    @discardableResult func makeContentFirstResponder() -> Bool { true }

    func owns(responder: NSResponder) -> Bool { false }
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { false }

    func applyAppearance(_ appearance: ThemeAppearance) {}
    func applyTerminalTextSize(_ size: TerminalTextSize) {}
    func setAccessibilityRuntimeTargetName(_ name: String) {}

    /// Runs where a real pane would reclaim ownership, which a test uses to act at that exact point in
    /// an open (it is the last thing the open does before the suspension it reports its landing after).
    var onRequestOwnership: (() -> Void)?
    func requestOwnershipIfNeeded() { onRequestOwnership?() }

    var canPerformFindActions: Bool { false }
    func find(_ sender: Any?) {}
    func findNext(_ sender: Any?) {}
    func findPrevious(_ sender: Any?) {}
    func useSelectionForFind(_ sender: Any?) {}

    func performShortcutForTesting(action: String, text: String?) {}
    func debugRefreshStateForTesting(skipOwnerAttach: Bool) {}
    func debugStateDump() -> TerminalSessionWindowDebugState { fatalError("not exercised by these tests") }
}
