import Testing
import WebKit

@testable import spacesui

/// Covers `CodePaneContentController`'s hibernation seam: `contentView` is a stable container that
/// survives the controller's whole lifetime, while the `WKWebView` itself is created by `activate()` and
/// torn down by `deactivate()` — the expensive resource a hidden tab must not keep alive.
@MainActor @Suite struct CodePaneContentControllerTests {
    private func makeController() -> CodePaneContentController {
        CodePaneContentController(paneID: "pane-1", deviceID: "device-1", workspaceID: "workspace-1", initialMode: .diff)
    }

    @Test func descriptorCarriesTheDeviceAndWorkspaceItShows() {
        let content = makeController()

        #expect(content.descriptor == .codePane(deviceID: "device-1", workspaceID: "workspace-1"))
    }

    @Test func activateInstallsAWebViewAndDeactivateTearsItDown() {
        let content = makeController()
        #expect(content.contentView.subviews.isEmpty, "no web view before activation")

        content.activate(focus: false)

        #expect(content.contentView.subviews.contains { $0 is WKWebView }, "activate() installs the web view")

        content.deactivate()

        #expect(content.contentView.subviews.isEmpty, "deactivate() tears the web view down")
    }

    /// The container view itself must not be recreated across the hibernation cycle: the pane tree holds
    /// onto `contentView` and re-parents it, so a fresh instance on every activate would orphan whatever
    /// the pane tree already placed in the view hierarchy.
    @Test func contentViewIdentityIsStableAcrossHibernation() {
        let content = makeController()
        let view = content.contentView

        content.activate(focus: false)
        content.deactivate()
        content.activate(focus: false)

        #expect(content.contentView === view)
    }

    @Test func reactivatingAfterDeactivateInstallsAFreshWebView() {
        let content = makeController()
        content.activate(focus: false)
        let firstWebView = content.contentView.subviews.first { $0 is WKWebView }
        content.deactivate()

        content.activate(focus: false)

        let secondWebView = content.contentView.subviews.first { $0 is WKWebView }
        #expect(secondWebView != nil)
        #expect(secondWebView !== firstWebView, "a new web process is created rather than reusing the torn-down one")
    }

    @Test func ownsRespondersOnlyWhileActivated() throws {
        let content = makeController()

        content.activate(focus: false)
        let webView = try #require(content.contentView.subviews.first { $0 is WKWebView })
        #expect(content.owns(responder: webView))

        content.deactivate()

        #expect(!content.owns(responder: webView), "a torn-down web view is no longer owned")
    }

    /// `close()` is the one-way teardown; it must leave the pane in the same hibernated state as
    /// `deactivate()` so a pane removed mid-preparation cannot leak its web view.
    @Test func closeTearsDownTheWebViewLikeDeactivate() {
        let content = makeController()
        content.activate(focus: false)

        content.close()

        #expect(content.contentView.subviews.isEmpty)
    }
}
