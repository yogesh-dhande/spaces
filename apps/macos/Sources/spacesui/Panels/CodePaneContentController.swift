import AppKit
import WebKit
import spacesterminalghostty

/// Which entry point created a code pane. Both the "Diff" and "Open file…" picker rows produce the
/// same `.codePane` descriptor today — Phase 1 is plumbing only, with nothing yet that renders a
/// diff or an editor differently — so the mode is carried purely as a runtime hint to the controller
/// and is never persisted. A restored pane always rebuilds as `.diff`, since the descriptor alone
/// cannot say which entry point created it.
enum CodePaneMode: Equatable {
    case diff
    case editor
}

/// Code-pane implementation of `PaneContentHosting`: a diff/editor surface backed by a `WKWebView`.
/// Phase 1 loads only an inline placeholder page; later phases point the web view at the daemon-served
/// diffs/editor bundle instead.
///
/// Hibernation seam: `contentView` (`rootView`) is a plain container that survives for the
/// controller's whole lifetime, so the pane tree can re-parent it across layout rebuilds without
/// recreating the controller — exactly like a terminal pane's view. The `WKWebView` itself is the
/// expensive resource: `activate()` creates it, `deactivate()` tears it down. A hidden tab therefore
/// holds no live web process; showing the pane again pays a fresh page load, which costs nothing for
/// today's static placeholder and will matter more once real content is loaded.
@MainActor final class CodePaneContentController: PaneContentHosting {
    let descriptor: PaneContentDescriptor
    let initialMode: CodePaneMode
    /// This pane's id — a code pane's only identity (see `PanelCoordinator.codePaneControllers`).
    /// Used to resolve the command palette's return-focus target, the code-pane counterpart of a
    /// terminal content controller's `sessionID`.
    let paneID: String
    private let rootView = NSView()
    private var webView: WKWebView?

    var onTitleChanged: ((String) -> Void)?

    init(paneID: String, deviceID: String, workspaceID: String, initialMode: CodePaneMode) {
        self.paneID = paneID
        self.descriptor = .codePane(deviceID: deviceID, workspaceID: workspaceID)
        self.initialMode = initialMode
        rootView.wantsLayer = true
        rootView.setAccessibilityIdentifier("code-pane-\(paneID)")
        bindAppearanceReactiveLayer(rootView) { view in view.layer?.backgroundColor = NSColor.activeTheme(\.terminal.background).cgColor }
    }

    var contentView: NSView { rootView }
    var displayTitle: String { "Code" }

    func activate(focus: Bool) {
        if webView == nil { installWebView() }
        if focus { _ = makeContentFirstResponder() }
    }

    /// Tears the web view down; `rootView` is left in place so the pane tree keeps a stable view to
    /// re-parent the next time this pane becomes visible.
    func deactivate() {
        webView?.removeFromSuperview()
        webView = nil
    }

    func close() { deactivate() }

    @discardableResult func makeContentFirstResponder() -> Bool {
        guard let webView else { return false }
        return webView.window?.makeFirstResponder(webView) ?? false
    }

    func owns(responder: NSResponder) -> Bool {
        guard let webView, let view = responder as? NSView else { return false }
        return view === webView || view.isDescendant(of: webView)
    }

    /// The web view handles its own keyboard input (typing, its native find, etc.) through the
    /// ordinary AppKit responder chain, so this controller never intercepts a key event itself —
    /// there is no Ghostty-style translation layer to run the way a terminal pane's does.
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { false }

    private func installWebView() {
        let webView = WKWebView(frame: rootView.bounds, configuration: WKWebViewConfiguration())
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.loadHTMLString(Self.placeholderHTML, baseURL: nil)
        rootView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        self.webView = webView
    }

    /// No external resources: later phases point this at a daemon-served bundle, but Phase 1 has none
    /// to load, so the placeholder is an inline page rather than a URL that would 404.
    ///
    /// `WKWebView` follows the app's effective appearance for `prefers-color-scheme`, so the page
    /// declares both palettes rather than hard-coding the dark one: without a light block the
    /// placeholder would stay dark-on-dark text under the app's light appearance.
    private static let placeholderHTML = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <style>
              html, body { margin: 0; height: 100%; background: #1e1e1e; }
              body { display: flex; align-items: center; justify-content: center; }
              p { margin: 0; color: #8a8a8a; font: 13px -apple-system, BlinkMacSystemFont, sans-serif; }
              @media (prefers-color-scheme: light) {
                html, body { background: #fafafa; }
                p { color: #6e6e6e; }
              }
            </style>
          </head>
          <body><p>Code pane</p></body>
        </html>
        """
}
