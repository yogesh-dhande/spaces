import AppKit
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

/// The pane the user is looking at is theirs to change. Sidebar reloads are event-driven — a bell, an
/// agent event, a poll — so a reload that resolves no selection must not move them, and it must never
/// move them to Alerts, which is reached only from the sidebar's Alerts row, its shortcut, leader
/// navigation past the first workspace, and the launch landing.
@Suite struct DetailPaneReconciliationRuleTests {
    private static let workspacePane = DetailPane.workspace(id: "workspace-1", deviceID: "local")

    /// A daemon that went offline answers with an empty placeholder overview, so its workspace going
    /// missing for a reload pass is the daemon blinking, not a deletion — the terminal in that pane stays.
    @Test func anOfflineDeviceLosingItsRowsKeepsTheWorkspacePane() {
        #expect(
            !AppKitController.unresolvedSelectionDropsWorkspacePane(
                pane: Self.workspacePane, hasSelectedWorkspace: true, paneDeviceLoadState: .offline("daemon restarting"), paneDeviceCompatibility: nil
            ))
    }

    /// Same for a reachable but wire-incompatible daemon: its section is cleared to show the block, and
    /// an empty section is not evidence about what the device owns.
    @Test func aWireIncompatibleDeviceLosingItsRowsKeepsTheWorkspacePane() {
        #expect(
            !AppKitController.unresolvedSelectionDropsWorkspacePane(
                pane: Self.workspacePane, hasSelectedWorkspace: true, paneDeviceLoadState: .loaded, paneDeviceCompatibility: .daemonTooOld))
    }

    /// A device still loading has not said anything yet either.
    @Test func aLoadingDeviceKeepsTheWorkspacePane() {
        #expect(
            !AppKitController.unresolvedSelectionDropsWorkspacePane(
                pane: Self.workspacePane, hasSelectedWorkspace: true, paneDeviceLoadState: .loading, paneDeviceCompatibility: nil))
    }

    /// An answering, wire-compatible device that stopped listing the workspace is believed: it was
    /// deleted from another client, and the pane would otherwise show dead controls forever.
    @Test func anAnsweringDeviceThatStoppedListingTheWorkspaceDropsThePane() {
        #expect(
            AppKitController.unresolvedSelectionDropsWorkspacePane(
                pane: Self.workspacePane, hasSelectedWorkspace: true, paneDeviceLoadState: .loaded, paneDeviceCompatibility: .compatible))
    }

    /// The device is gone from the sidebar altogether (unpaired), so nothing can bring the workspace back.
    @Test func aWorkspacePaneWhoseDeviceIsGoneIsDropped() {
        #expect(
            AppKitController.unresolvedSelectionDropsWorkspacePane(
                pane: Self.workspacePane, hasSelectedWorkspace: true, paneDeviceLoadState: nil, paneDeviceCompatibility: nil))
    }

    /// The selection was cleared deliberately (empty-space click, collapsing the project holding it), so
    /// the workspace pane has no reason left to be on screen whatever its device says.
    @Test func aClearedSelectionDropsTheWorkspacePane() {
        #expect(
            AppKitController.unresolvedSelectionDropsWorkspacePane(
                pane: Self.workspacePane, hasSelectedWorkspace: false, paneDeviceLoadState: .offline("daemon restarting"),
                paneDeviceCompatibility: nil))
    }

    /// Only a workspace pane is ever taken down by a reconcile. Alerts stays because the user asked for
    /// it, the placeholder is already the neutral pane, and a compatibility block is reconciled by the
    /// verdict that raised it.
    @Test func noOtherPaneIsTakenDownByAReconcile() {
        for pane in [DetailPane.none, .alerts, .compatibilityBlock(deviceID: "local")] {
            #expect(
                !AppKitController.unresolvedSelectionDropsWorkspacePane(
                    pane: pane, hasSelectedWorkspace: false, paneDeviceLoadState: .loaded, paneDeviceCompatibility: .compatible),
                "\(pane) is not a reconcile's to replace")
        }
    }
}

/// Every shortcut is stored in the client database, and the leader-backed ones are stored bare — the
/// leader modifiers are applied when the setting is read. So a read that fails and answers with the
/// stored default hands back an unmodified letter: "a" alone would fire Alerts.
@Suite struct ShortcutSpecReadFailureTests {
    private struct ClientDatabaseUnavailable: Error {}

    private func storedResolver(_ values: [String: String]) -> AppKitController.ShortcutSettingResolver {
        AppKitController.ShortcutSettingResolver { key in values[key] }
    }

    private func failingResolver() -> AppKitController.ShortcutSettingResolver {
        AppKitController.ShortcutSettingResolver { _ in throw ClientDatabaseUnavailable() }
    }

    private static let leader: Set<HotkeyModifier> = [.cmd, .alt]

    /// The unset setting is not a failure: it resolves to the default chord with the leader applied.
    @Test func anUnsetShortcutResolvesToTheLeaderBackedDefault() throws {
        let resolved = try #require(
            AppKitController.resolvedShortcutSpec(storedResolver([:]), setting: .guiAlertsShortcut, current: nil, leaderModifiers: Self.leader))
        #expect(resolved.modifiers == [.cmd, .alt], "the alerts shortcut is only ever the leader plus a letter")
        #expect(resolved.key == "a")
    }

    /// A transient client-database failure leaves the shortcut on the chord already in effect instead of
    /// degrading it to the leaderless letter the default is stored as.
    @Test func aFailedReadKeepsTheChordAlreadyInEffect() throws {
        let inEffect = try #require(
            AppKitController.resolvedShortcutSpec(
                storedResolver([ClientSettingsKey.guiAlertsShortcut: "a"]), setting: .guiAlertsShortcut, current: nil,
                leaderModifiers: Self.leader))

        let afterFailedRead = AppKitController.resolvedShortcutSpec(
            failingResolver(), setting: .guiAlertsShortcut, current: inEffect, leaderModifiers: Self.leader)

        #expect(afterFailedRead == inEffect)
        #expect(afterFailedRead?.modifiers.isEmpty == false, "a failed read must never leave a bare letter bound to Alerts")
    }

    /// A user-chosen chord survives the same failure, including one that is not the default at all.
    @Test func aFailedReadKeepsACustomChord() throws {
        let custom = HotkeySpec(key: "j", modifiers: [.ctrl, .shift])
        #expect(
            AppKitController.resolvedShortcutSpec(failingResolver(), setting: .guiSidebarNextShortcut, current: custom, leaderModifiers: Self.leader)
                == custom)
    }

    /// The launch pass has no chord in effect yet, so a read that fails then must still install a
    /// usable chord: the safe default, leader-composed for a leader-backed setting — never nil, which
    /// would unregister the shortcut for the life of the outage, and never the bare stored letter.
    @Test func aFailedFirstReadInstallsTheSafeDefault() throws {
        let alerts = try #require(
            AppKitController.resolvedShortcutSpec(failingResolver(), setting: .guiAlertsShortcut, current: nil, leaderModifiers: Self.leader))
        #expect(alerts.modifiers == Self.leader, "a leader-backed default installed on a failed first read carries the leader")
        #expect(alerts.key == "a")

        let summon = try #require(
            AppKitController.resolvedShortcutSpec(failingResolver(), setting: .guiHotkey, current: nil, leaderModifiers: Self.leader))
        #expect(summon.modifiers.isEmpty == false, "the global summon hotkey stays registered on a failed first read")
    }
}

extension ProcessProfileEnvironmentSuites {
    /// Drives the real reconcile entry points on a live `AppKitController` and reads the pane they leave
    /// on screen. The rule suite above covers the decision; this covers the wiring — which pane
    /// `refreshSelection` and the summon refresh actually end up presenting.
    ///
    /// Builds the controller the way `SidebarRowRepaintTests` does (a fabricated lease/profile over a
    /// throwaway temp directory) and nests under `ProcessProfileEnvironmentSuites` for the same reason:
    /// it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class DetailPaneReconciliationTests {
        private static let projectID = "project-1"
        private static let workspaceID = "workspace-1"

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

        /// One local device holding a single git project and workspace.
        private func populatedSection(deviceID: String) -> AppKitController.DeviceSection {
            let overview = SpacesDeviceOverviewPayload(
                projects: [
                    SpacesDeviceProjectSummary(id: Self.projectID, name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")
                ],
                workspaces: [
                    SpacesDeviceWorkspaceSummary(
                        id: Self.workspaceID, projectID: Self.projectID, projectName: "Project", branch: "feature", baseBranch: "main",
                        dir: "/tmp/project-feature", isRunning: true, isHidden: false, isDefault: false, sessionCount: 1, codingAgentRows: [],
                        terminalRows: [])
                ], sessions: [])
            let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
            return AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: .loaded, device: nil, projects: mapped.projects,
                workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, overview: overview,
                compatibility: .compatible)
        }

        /// The same device with nothing in it, as it renders while unreachable or wire-incompatible.
        private func emptySection(deviceID: String, loadState: AppKitController.SidebarDeviceLoadState, compatibility: SpacesWireCompatibility?)
            -> AppKitController.DeviceSection
        {
            AppKitController.DeviceSection(
                deviceID: deviceID, deviceName: "This Mac", isLocal: true, loadState: loadState, device: nil, compatibility: compatibility)
        }

        /// Puts the workspace pane on screen with the workspace selected, without building the real
        /// panel: the paths under test are the ones that never resolve a workspace, so the pane's
        /// identity is all they read.
        private func showWorkspacePane(_ controller: AppKitController) {
            controller.deviceSections = [populatedSection(deviceID: controller.localDeviceID)]
            controller.rebuildFlatSidebarData()
            controller.presentDetailPane(.workspace(id: Self.workspaceID, deviceID: controller.localDeviceID), presentation: .userNavigation)
            controller.selectedProjectID = Self.projectID
            controller.selectedWorkspaceID = Self.workspaceID
        }

        private func applyReload(_ controller: AppKitController, section: AppKitController.DeviceSection) {
            controller.deviceSections = [section]
            controller.rebuildFlatSidebarData()
            controller.refreshSelection()
        }

        /// The daemon restarting takes its rows away for a pass. The terminal in the pane must survive it.
        @Test func aReloadThatLosesAnOfflineDevicesWorkspaceKeepsThePane() {
            let controller = makeController()
            showWorkspacePane(controller)

            applyReload(controller, section: emptySection(deviceID: controller.localDeviceID, loadState: .offline("unreachable"), compatibility: nil))

            #expect(controller.detailPane == .workspace(id: Self.workspaceID, deviceID: controller.localDeviceID))
            #expect(controller.selectedWorkspaceID == Self.workspaceID, "the selection is what restores the pane when the daemon returns")
        }

        /// A workspace deleted from another client is gone for good, so the pane resolves to the neutral
        /// placeholder — and to the placeholder rather than Alerts.
        @Test func aWorkspaceDeletedElsewhereResolvesToThePlaceholderNotAlerts() {
            let controller = makeController()
            showWorkspacePane(controller)

            applyReload(controller, section: emptySection(deviceID: controller.localDeviceID, loadState: .loaded, compatibility: .compatible))

            #expect(controller.detailPane == DetailPane.none)
            #expect(controller.selectedWorkspaceID == nil, "a selection nothing lists would re-enter this branch on every later reload")
        }

        /// The plain case behind the report: a reload arriving while nothing is selected. It used to end
        /// in Alerts, which is what pulled users out of a focused terminal.
        @Test func aReloadWithNothingSelectedLeavesThePaneAlone() {
            let controller = makeController()
            controller.deviceSections = [populatedSection(deviceID: controller.localDeviceID)]
            controller.rebuildFlatSidebarData()

            controller.refreshSelection()

            #expect(controller.detailPane == DetailPane.none)
        }

        /// The summon hotkey with no tracked focused window carries no view intent, so it re-renders and
        /// nothing more — not even the reconcile a reload would be entitled to.
        @Test func summonWithNoFocusedWorkspaceNeverChangesThePane() {
            let controller = makeController()
            showWorkspacePane(controller)
            controller.deviceSections = [emptySection(deviceID: controller.localDeviceID, loadState: .loaded, compatibility: .compatible)]
            controller.rebuildFlatSidebarData()

            controller.refreshWorkspaceSelectionForActivation(focusedWorkspaceID: nil)

            #expect(controller.detailPane == .workspace(id: Self.workspaceID, deviceID: controller.localDeviceID))
        }

        /// The same summon from the placeholder: it stays on the placeholder rather than landing on Alerts.
        @Test func summonFromThePlaceholderStaysOnThePlaceholder() {
            let controller = makeController()
            controller.deviceSections = [populatedSection(deviceID: controller.localDeviceID)]
            controller.rebuildFlatSidebarData()

            controller.refreshWorkspaceSelectionForActivation(focusedWorkspaceID: nil)

            #expect(controller.detailPane == DetailPane.none)
        }
    }
}
