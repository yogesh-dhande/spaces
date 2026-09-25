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
#endif
