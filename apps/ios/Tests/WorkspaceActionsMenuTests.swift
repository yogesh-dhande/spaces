#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    @testable import SpacesMobile

    /// `WorkspaceActionsMenu`'s pure lifecycle-gating decision (`offersStart`/`offersLifecycle`), exercised
    /// directly on the view value rather than through its rendered body: no SwiftUI hosting is needed to
    /// pin which actions a workspace's kind and run state offer.
    @MainActor final class WorkspaceActionsMenuTests: XCTestCase {
        private func menu(_ workspace: SpacesDeviceWorkspaceSummary) -> WorkspaceActionsMenu {
            WorkspaceActionsMenu(
                workspace: workspace, isMutating: false, isDeleting: false, onStart: {}, onRestart: {}, onStop: {}, onNewTerminal: {}, onHide: {},
                onDelete: {})
        }

        /// The home project has no configured processes to start and no lifecycle of its own: its one
        /// workspace is marked running by an ordinary ad hoc terminal launch and stops again when the last
        /// terminal ends, so the menu offers neither Start nor Restart/Stop for it.
        func testHomeWorkspaceOffersNoLifecycleControl() {
            let home = makeHomeWorkspace()

            XCTAssertFalse(menu(home).offersLifecycle)
            XCTAssertFalse(menu(home).offersStart)
        }

        /// An ordinary stopped workspace keeps offering Start, the same as before the home row existed:
        /// the lifecycle gate is specific to the home project's kind, not to being stopped.
        func testOrdinaryStoppedWorkspaceStillOffersStart() {
            let stopped = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo/feature",
                isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false)

            XCTAssertTrue(menu(stopped).offersLifecycle)
            XCTAssertTrue(menu(stopped).offersStart)
        }

        /// The home project's workspace under Demo Mode: no lifecycle (checked above), no ad hoc terminal
        /// (Demo Mode's backend cannot open one), no Hide, and no Delete (home workspaces are undeletable).
        /// Every item condition is false, so the pill this menu backs must not be shown at all; rendering
        /// it anyway is the bug (an ellipsis pill opening to an empty "~" section).
        func testHomeWorkspaceInDemoModeHasNoActions() {
            let home = makeHomeWorkspace()
            let menu = WorkspaceActionsMenu(
                workspace: home, isMutating: false, isDeleting: false, onStart: {}, onRestart: {}, onStop: {}, onNewTerminal: nil, onHide: nil,
                onDelete: nil)

            XCTAssertFalse(menu.hasActions)
        }

        /// One available item is enough to keep the pill: `hasActions` must not require lifecycle control,
        /// only that at least one of the per-item predicates is true.
        func testWorkspaceWithOnlyHideHasActions() {
            let home = makeHomeWorkspace()
            let menu = WorkspaceActionsMenu(
                workspace: home, isMutating: false, isDeleting: false, onStart: {}, onRestart: {}, onStop: {}, onNewTerminal: nil, onHide: {},
                onDelete: nil)

            XCTAssertTrue(menu.hasActions)
        }

        /// Same as above for New Terminal, the item Demo Mode specifically withholds: a non-Demo-Mode
        /// workspace with no other item still keeps its pill.
        func testWorkspaceWithOnlyNewTerminalHasActions() {
            let home = makeHomeWorkspace()
            let menu = WorkspaceActionsMenu(
                workspace: home, isMutating: false, isDeleting: false, onStart: {}, onRestart: {}, onStop: {}, onNewTerminal: {}, onHide: nil,
                onDelete: nil)

            XCTAssertTrue(menu.hasActions)
        }

        /// A stopped standard workspace offering only Start (no New Terminal/Hide/Delete wired) still has
        /// actions: `hasActions` must fold in the lifecycle items, not just the three optional closures.
        func testStoppedWorkspaceOfferingOnlyStartHasActions() {
            let stopped = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: "project-1", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/repo/feature",
                isRunning: false, isHidden: false, isDefault: false, hasTrackedRuntimeIndicators: false)
            let menu = WorkspaceActionsMenu(
                workspace: stopped, isMutating: false, isDeleting: false, onStart: {}, onRestart: {}, onStop: {}, onNewTerminal: nil, onHide: nil,
                onDelete: nil)

            XCTAssertTrue(menu.hasActions)
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
