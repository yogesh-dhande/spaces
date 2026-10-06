import AppKit
import Testing
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Renders the real Alerts pane in a window and feeds its row click recognizers the mouse-down events
    /// a user's click would produce. Nests under `ProcessProfileEnvironmentSuites` and builds its controller
    /// the way `AlertsDetailRebuildTests` does, since it mutates `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class AlertsDismissClickTests {
        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?
        private var window: NSWindow?

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

        private static let attentionIDs = [
            "alert:local:session:session-1:bell:2026-06-28T09:00:00Z", "alert:local:session:session-2:bell:2026-06-28T09:00:00Z",
            "alert:local:session:session-3:bell:2026-06-28T09:00:00Z",
        ]

        private func group() -> AppKitController.AlertsGroup {
            AppKitController.AlertsGroup(
                projectName: "Project", workspaceID: "workspace-1", workspaceName: "feature", workspaceBranch: "feature",
                isFromHiddenWorkspace: false,
                items: Self.attentionIDs.enumerated().map { index, attentionID in
                    AppKitController.AlertsAttentionEntry(
                        attentionID: attentionID, kind: .bell, icon: "terminal", iconTint: .terminal, label: "box \(index + 1)",
                        detail: "vim file\(index).swift", shortcut: "", processStatus: nil, agentStatus: nil, countsTowardBadge: true, eventDate: nil,
                        focusRequest: .terminalSession(workspaceID: "workspace-1", sessionID: "session-\(index + 1)"))
                })
        }

        private func allSubviews(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { allSubviews(of: $0) } }

        /// Renders the pane inside a window and lays it out, so every row has the frame it has on screen.
        private func renderPane() -> AppKitController {
            let controller = makeController()
            controller.deviceModel.alertsGroups = [group()]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            let host = window.contentView!
            controller.detailContainer.removeFromSuperview()
            host.addSubview(controller.detailContainer)
            NSLayoutConstraint.activate([
                controller.detailContainer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                controller.detailContainer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                controller.detailContainer.topAnchor.constraint(equalTo: host.topAnchor),
                controller.detailContainer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            self.window = window
            controller.alerts.showAlertsDetail()
            host.layoutSubtreeIfNeeded()
            controller.detailContainer.layoutSubtreeIfNeeded()
            return controller
        }

        private func mouseDown(at windowPoint: NSPoint, in window: NSWindow) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }

        private func windowCenter(of view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }

        /// A row sits below the table's header line and divider, so its frame origin is never zero. A veto
        /// that hands the row's own coordinates to `hitTest`, which expects the superview's, lands outside
        /// the row, hits nothing, and lets an X click also focus the terminal.
        @Test func aClickOnARowsDismissButtonNeverStartsTheRowsFocusClick() throws {
            let controller = renderPane()
            let window = try #require(window)
            let rows = allSubviews(of: controller.detailContainer).compactMap { $0 as? ClickableRowView }
            #expect(rows.count == Self.attentionIDs.count)

            for row in rows {
                let recognizer = try #require(row.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }.first)
                let delegate = try #require(recognizer.delegate)
                let dismiss = try #require(
                    allSubviews(of: row).compactMap { $0 as? NSButton }.first { Self.attentionIDs.contains($0.identifier?.rawValue ?? "") })
                let label = try #require(row.labelField)

                let onDismiss = try mouseDown(at: windowCenter(of: dismiss), in: window)
                #expect(
                    delegate.gestureRecognizer?(recognizer, shouldAttemptToRecognizeWith: onDismiss) == false,
                    "a click on \(dismiss.identifier?.rawValue ?? "?") must not start the row's focus click")

                let onLabel = try mouseDown(at: windowCenter(of: label), in: window)
                #expect(
                    delegate.gestureRecognizer?(recognizer, shouldAttemptToRecognizeWith: onLabel) == true,
                    "a click on the row's label must still start the row's focus click")
            }
        }
    }
}
