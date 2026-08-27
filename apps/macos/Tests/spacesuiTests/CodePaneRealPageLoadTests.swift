import Testing
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

/// A `CodePaneHosting` double with no device/workspace on file, mirroring
/// `CodePaneContentControllerTests`'s `EmptyCodePaneHostingDouble` (fileprivate there, so this suite
/// keeps its own copy). Sufficient here: this suite never services an RPC, only drives the real page
/// load through to its `ready` handshake.
@MainActor private final class EmptyCodePaneHostingDouble: CodePaneHosting {
    func codePaneDevice(workspaceID: String) -> SpacesPairedDeviceRecord? { nil }
    func codePaneWorkspaceInfo(workspaceID: String) -> (name: String, baseBranch: String?)? { nil }
    func codePaneCurrentAppearance() -> ThemeAppearance { .dark }
    func codePaneRunningAgents(workspaceID: String) -> [CodePaneRunningAgent] { [] }
    func codePaneInstallBackgroundCommandSession(workspaceID: String, deviceID: String, response: SpacesDeviceAPIResponse) {}
}

/// Drives a REAL `WKWebView` through `CodePaneContentController`'s real `activate()`/`deactivate()`
/// lifecycle and asserts the built bundle's JS actually ran far enough to deliver the `ready`
/// handshake (`isReady` flips true). This is the regression guard for the bundle actually loading and
/// executing: every other `CodePaneContentControllerTests` case substitutes a `RecordingCodePaneScriptEvaluator`
/// for `scriptEvaluator` after activation (see that seam's doc comment), so none of them ever let the
/// real page run its own JS. A file:// load of the built bundle renders a blank page (its module script
/// and crossorigin stylesheet are CORS-fetched, and file:// is an opaque origin WebKit blocks both
/// against) without tripping any of those unit tests, since they never depend on `isReady` becoming
/// true through the real page; only this suite would have caught it.
@MainActor @Suite struct CodePaneRealPageLoadTests {
    private let hostingDouble = EmptyCodePaneHostingDouble()

    private func makeController() -> CodePaneContentController {
        CodePaneContentController(
            paneID: "pane-real-load", deviceID: "device-1", workspaceID: "workspace-1", initialMode: .diff, hosting: hostingDouble)
    }

    /// Polls `controller.isReady` until it flips true or `timeout` elapses, sleeping between checks so
    /// the run loop gets to deliver the page's `WKScriptMessage` callback that flips it.
    private func waitUntilReady(_ controller: CodePaneContentController, timeout: Duration = .seconds(30)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !controller.isReady, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return controller.isReady
    }

    @Test func realBundleLoadDeliversReadyHandshake() async {
        let content = makeController()
        content.activate(focus: false)

        let becameReady = await waitUntilReady(content)
        #expect(becameReady, "the code pane's built bundle never delivered its ready handshake through a real WKWebView")

        content.deactivate()
        content.close()
    }
}
