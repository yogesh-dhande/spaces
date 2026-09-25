#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    @testable import SpacesMobile

    /// `WorkspaceControlBar`'s pure lifecycle-gating decision (`offersStart`/`offersLifecycle`), exercised
    /// directly on the view value rather than through its rendered body: no SwiftUI hosting is needed to
    /// pin which controls a workspace's kind and run state offer.
    @MainActor final class WorkspaceControlBarTests: XCTestCase {
        private func bar(_ workspace: SpacesDeviceWorkspaceSummary) -> WorkspaceControlBar {
            WorkspaceControlBar(workspace: workspace, isBusy: false, onStart: {}, onRestart: {}, onStop: {}, onNewTerminal: {})
        }

        /// The home project has no configured processes to start and no lifecycle of its own: its one
        /// workspace is marked running by an ordinary ad hoc terminal launch and stops again when the last
        /// terminal ends, so the bar offers neither Start nor Restart/Stop for it.
        func testHomeWorkspaceOffersNoLifecycleControl() {
            let home = makeHomeWorkspace()

            XCTAssertFalse(bar(home).offersLifecycle)
            XCTAssertFalse(bar(home).offersStart)
        }

        /// An ordinary stopped workspace keeps offering Start, the same as before the home row existed:
        /// the lifecycle gate is specific to the home project's kind, not to being stopped.
        func testOrdinaryStoppedWorkspaceStillOffersStart() {
            let stopped = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo/feature",
                isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false)

            XCTAssertTrue(bar(stopped).offersLifecycle)
            XCTAssertTrue(bar(stopped).offersStart)
        }
    }

    /// `SpacesDeviceWorkspaceSummary.displayName` for the home project's workspace.
    @MainActor final class HomeWorkspaceDisplayNameTests: XCTestCase {
        /// The home project's single workspace shows `~` rather than the home directory's last path
        /// component, which would otherwise read as the account's user name.
        func testDisplayNameIsTildeForAHomeWorkspace() {
            let home = makeHomeWorkspace(dir: "/Users/someone")

            XCTAssertEqual(home.displayName, "~")
        }
    }

    /// The Hide-workspace confirmation dialog copy (`HideWorkspaceConfirmation`), shared by `SpacesTabView`'s
    /// per-row Hide and `WorkspaceVisibilitySheet`'s bulk hide. Both dialogs delegate their button title and
    /// message to this enum rather than deciding their own wording, so these cases stand in for both;
    /// `WorkspaceVisibilitySheet.PendingHide` is `private` to its own file and not constructible from a
    /// test target, but it carries no logic of its own left to test separately.
    @MainActor final class HideWorkspaceConfirmationTests: XCTestCase {
        /// The home project has no lifecycle and is never stopped on hide, so it needs no confirmation at
        /// all: both surfaces hide it directly instead of presenting a dialog, and `copy(for:)` says so by
        /// returning `nil` even when an open terminal makes `isRunning` true.
        func testRunningHomeWorkspaceYieldsNoConfirmation() {
            let home = makeHomeWorkspace(isRunning: true)

            XCTAssertNil(HideWorkspaceConfirmation.copy(for: home))
        }

        /// An ordinary running workspace still gets the stop warning, unchanged by the home-project carve
        /// out above.
        func testRunningOrdinaryWorkspaceGetsStopAndHideWording() {
            let running = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo/feature",
                isRunning: true, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: true)

            let copy = HideWorkspaceConfirmation.copy(for: running)

            XCTAssertEqual(copy?.buttonTitle, "Stop and Hide")
            XCTAssertTrue(copy?.message.contains("stops its processes and coding agents") ?? false)
        }

        /// A stopped ordinary workspace gets the plain "Hide" wording, distinguishing it from the home
        /// project's `nil` above: both read as a bare hide, but only the home project skips the dialog
        /// entirely.
        func testStoppedOrdinaryWorkspaceGetsPlainHideWording() {
            let stopped = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo/feature",
                isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false)

            let copy = HideWorkspaceConfirmation.copy(for: stopped)

            XCTAssertEqual(copy?.buttonTitle, "Hide")
            XCTAssertTrue(copy?.message.contains("leaves this list") ?? false)
        }
    }
#endif
