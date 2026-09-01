import AppKit
import Testing
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Drives the real Alerts pane through the refresh path that runs many times a second while a coding
    /// agent streams, and reads the view instances it leaves behind. A rebuild replaces every card and
    /// dismiss button in the pane, so a card destroyed between mouse-down and mouse-up swallows the
    /// click: the contract this suite asserts is that a refresh which renders the same content leaves
    /// the very same views on screen.
    ///
    /// Builds an `AppKitController` the way `MainWindowCloseBehaviorTests` does (a fabricated
    /// lease/profile over a throwaway temp directory) and nests under `ProcessProfileEnvironmentSuites`
    /// for the same reason: it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class AlertsDetailRebuildTests {
        private static let bellAttentionID = "alert:local:session:session-1:bell:2026-06-28T09:00:00Z"
        private static let processAttentionID = "alert:local:process:run-1:2026-06-28T09:00:00Z"

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

        /// One workspace's bell alert, whose detail line is the session's live title.
        private func bellGroup(liveTitle: String?) -> AppKitController.AlertsGroup {
            AppKitController.AlertsGroup(
                projectName: "Project", workspaceID: "workspace-1", workspaceName: "feature", workspaceBranch: "feature",
                isFromHiddenWorkspace: false,
                items: [
                    AppKitController.AlertsAttentionEntry(
                        attentionID: Self.bellAttentionID, icon: "terminal", iconTint: .terminal, label: "build box", detail: liveTitle, shortcut: "",
                        processStatus: nil, agentStatus: nil, countsTowardBadge: true, eventDate: nil,
                        focusRequest: .terminalSession(workspaceID: "workspace-1", sessionID: "session-1"))
                ])
        }

        /// The same workspace with a second alert, which is a change of shape rather than of text.
        private func bellAndProcessGroup(liveTitle: String?) -> AppKitController.AlertsGroup {
            let bell = bellGroup(liveTitle: liveTitle).items[0]
            return AppKitController.AlertsGroup(
                projectName: "Project", workspaceID: "workspace-1", workspaceName: "feature", workspaceBranch: "feature",
                isFromHiddenWorkspace: false,
                items: [
                    bell,
                    AppKitController.AlertsAttentionEntry(
                        attentionID: Self.processAttentionID, icon: "bolt.horizontal.circle", iconTint: .warning, label: "web", detail: "npm run dev",
                        shortcut: "", processStatus: .exited, agentStatus: nil, countsTowardBadge: true, eventDate: nil,
                        focusRequest: .workspaceProcess(workspaceID: "workspace-1", processID: "run-1")),
                ])
        }

        /// Every alert row currently on screen, in render order. Reads the detail container itself, so a
        /// row the pane replaced can never be mistaken for the one it replaced.
        private func renderedRows(_ controller: AppKitController) -> [ClickableRowView] {
            var found: [ClickableRowView] = []
            func walk(_ view: NSView) {
                if let row = view as? ClickableRowView { found.append(row) }
                for subview in view.subviews { walk(subview) }
            }
            for subview in controller.detailContainer.subviews { walk(subview) }
            return found
        }

        private func detailText(_ row: ClickableRowView) -> String { row.detailField?.stringValue ?? "" }

        @Test func aRefreshThatChangesNothingLeavesTheSameCardsOnScreen() throws {
            let controller = makeController()
            controller.alertsGroups = [bellGroup(liveTitle: "vim main.swift")]
            controller.alerts.showAlertsDetail()
            let rendered = try #require(renderedRows(controller).first)

            controller.alerts.showAlertsDetail()

            let afterRefresh = renderedRows(controller)
            #expect(afterRefresh.count == 1)
            #expect(afterRefresh.first === rendered, "an unchanged refresh must not replace the alert card")
        }

        /// The live title of a streaming session changes on every frame. It is the row's detail text and
        /// nothing else, so it is written into the field the row already has.
        @Test func aLiveTitleChangeUpdatesTheCardInPlace() throws {
            let controller = makeController()
            controller.alertsGroups = [bellGroup(liveTitle: "vim main.swift")]
            controller.alerts.showAlertsDetail()
            let rendered = try #require(renderedRows(controller).first)
            #expect(detailText(rendered) == "vim main.swift")

            controller.alertsGroups = [bellGroup(liveTitle: "vim other.swift")]
            controller.alerts.showAlertsDetail()

            let afterRefresh = try #require(renderedRows(controller).first)
            #expect(afterRefresh === rendered, "a live-title change must not replace the alert card")
            #expect(detailText(afterRefresh) == "vim other.swift")
            #expect(afterRefresh.accessibilityValue() as? String == "vim other.swift")
        }

        @Test func aNewAlertRebuildsThePane() throws {
            let controller = makeController()
            controller.alertsGroups = [bellGroup(liveTitle: "vim main.swift")]
            controller.alerts.showAlertsDetail()
            let rendered = try #require(renderedRows(controller).first)

            controller.alertsGroups = [bellAndProcessGroup(liveTitle: "vim main.swift")]
            controller.alerts.showAlertsDetail()

            let afterRefresh = renderedRows(controller)
            #expect(afterRefresh.count == 2)
            #expect(afterRefresh.first !== rendered, "an alert arriving must build the pane again")
        }

        /// Navigating away takes the alerts views off screen, so coming back has to build them even
        /// though the content never changed.
        @Test func returningToThePaneBuildsItAgain() throws {
            let controller = makeController()
            controller.alertsGroups = [bellGroup(liveTitle: "vim main.swift")]
            controller.alerts.showAlertsDetail()
            let rendered = try #require(renderedRows(controller).first)

            controller.showPlaceholder()
            #expect(renderedRows(controller).isEmpty)
            controller.alerts.showAlertsDetail()

            #expect(renderedRows(controller).first !== rendered)
        }
    }
}
