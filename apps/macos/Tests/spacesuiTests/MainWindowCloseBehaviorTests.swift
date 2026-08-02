import AppKit
import Testing
import spacesterminalcore

@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// Exercises the main window's close-to-hide contract: closing the main window (red traffic-light
    /// button, or a programmatic `performClose`) routes through `windowShouldClose`, which orders the
    /// window out instead of letting AppKit tear it down, and `applicationShouldHandleReopen` brings it
    /// back when the app is reactivated with no visible windows (Dock icon click, app reopen).
    ///
    /// Constructing a full `AppKitController` needs a `SpacesAppLaunchContext`, which in production is
    /// only reachable through `SpacesLeaseCoordinator.prepareAppLaunchContext()` — real, machine-wide
    /// process-lease file coordination that would make this suite contend with any other Spaces instance
    /// running on the machine. This suite builds the context by hand instead: a fabricated lease/profile
    /// pointing at a throwaway temp directory, via `@testable import workspacecore` for
    /// `SpacesProcessLease`'s internal initializer, so the test never touches real lease state.
    ///
    /// Nests under `ProcessProfileEnvironmentSuites` (rather than declaring its own `.serialized`) because
    /// it mutates the process-global `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` in `init`/`deinit`; see that
    /// parent's doc comment for why a per-suite trait alone is not enough.
    @MainActor
    @Suite final class MainWindowCloseBehaviorTests {
        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // AppKitController.init reads the default client database (for the stored theme id) through
            // the process-global SPACES_DB_PATH/SPACES_RUNTIME_DIR overrides, same as the launch context
            // itself would in production; point both at this suite's throwaway directory.
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
                pid: ProcessInfo.processInfo.processIdentifier, executablePath: "/tmp/spaces-test", profileRoot: root.path,
                token: UUID().uuidString, acquiredAt: "2026-01-01T00:00:00Z")
            // A real SpacesProcessLease normally guards a live lease file; this one points at a directory
            // that is never created, so its deinit-time release() is a harmless no-op (readOwner finds
            // nothing to match against).
            let lease = SpacesProcessLease(
                owner: owner, leaseDirectoryPath: root.appendingPathComponent("app-owner-lease").path, metadataPath: "unused",
                fileManager: .default)
            let context = SpacesAppLaunchContext(profile: profile, appOwnerLease: lease, desktopControlState: .passive(owner))
            return AppKitController(launchContext: context)
        }

        private func makeWindow() -> NSWindow {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled, .resizable, .closable], backing: .buffered,
                defer: false)
        }

        @Test func windowShouldCloseHidesTheMainWindowInsteadOfLettingAppKitCloseIt() {
            let controller = makeController()
            let mainWindow = makeWindow()
            controller.window = mainWindow
            mainWindow.orderFront(nil)

            let shouldClose = controller.windowShouldClose(mainWindow)

            #expect(!shouldClose)
            // The window must still be the same live instance the controller references (not released by
            // AppKit's default close path), just hidden.
            #expect(controller.window === mainWindow)
            #expect(!mainWindow.isVisible)
        }

        @Test func windowShouldCloseAllowsClosingUnrelatedWindows() {
            let controller = makeController()
            controller.window = makeWindow()
            let otherWindow = makeWindow()

            #expect(controller.windowShouldClose(otherWindow))
        }

        @Test func applicationShouldHandleReopenSkipsRepresentingWhenTheMainWindowIsAlreadyVisible() {
            let controller = makeController()
            let mainWindow = makeWindow()
            controller.window = mainWindow
            mainWindow.orderFront(nil)

            // The method gates on the main window's own visibility, not the aggregate `hasVisibleWindows`
            // flag (which counts every app window, including panel windows) — so the outcome must be the
            // same regardless of what the caller passes for it.
            #expect(controller.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
            #expect(controller.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        }

        // Two branches would re-present the main window via `ensureMainWindowVisible()`, which routes
        // through `presentWindowIfAllowed` — guarded only by `AppKitController.isRunningUnderXCTest`
        // (checks `XCTestConfigurationFilePath`): the main window hidden with `hasVisibleWindows: false`
        // (a Dock click while no Spaces window at all is visible), and the main window hidden with
        // `hasVisibleWindows: true` (a Dock click while a panel window is still visible — the case this
        // method exists to get right, since the main window being hidden is what matters, not the
        // aggregate flag). That guard does not trip for Swift Testing suites run through `swift test` /
        // `swiftpm.sh test`: per `SpacesTestHost.isRunningUnderXCTest()`'s doc comment, the Swift Testing
        // lane has no `.xctest` path in argv and sets no `XCTestConfigurationFilePath`, unlike the
        // linked-in-`XCTestCase` signal that guard doesn't check. Calling either branch here would really
        // invoke `NSApp.activate(ignoringOtherApps:)` and force-order a bogus window to the front during a
        // unit test run, so both are left untested rather than fought.
    }
}
