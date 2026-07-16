import AppKit

/// The window shell for one globally-scoped panel: an extra Spaces window whose entire
/// content is a `WorkspacePanelView` mixing terminal panes from any workspace. Owned by
/// `PanelCoordinator`; all layout state lives there — this type only manages the
/// NSWindow (frame, title, close routing).
@MainActor final class PanelWindowController: NSObject, NSWindowDelegate {
    let panelWindowID: String
    let window: NSWindow

    /// User-initiated close (red button or performClose). The coordinator tears the
    /// panel down and closes the window itself through its single dismiss funnel, so
    /// this always answers "don't close yet" to AppKit.
    var onUserClose: (() -> Void)?
    /// Move/resize hook; the coordinator re-persists the panel so the frame survives
    /// relaunch.
    var onFrameChanged: (() -> Void)?

    init(panelWindowID: String, panelView: WorkspacePanelView, frame: NSRect?) {
        self.panelWindowID = panelWindowID
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init()
        window.title = "Terminals"
        window.setAccessibilityIdentifier("spaces-panel-window-\(panelWindowID)")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The persisted rect is the window frame (not a content rect), so restore it
        // through setFrame or the titlebar height would compound across relaunches.
        if let frame { window.setFrame(frame, display: false) } else { window.center() }

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        panelView.removeFromSuperview()
        content.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.topAnchor.constraint(equalTo: content.topAnchor), panelView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: content.trailingAnchor), panelView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        onUserClose?()
        return false
    }

    public func windowDidMove(_ notification: Notification) { onFrameChanged?() }

    public func windowDidEndLiveResize(_ notification: Notification) { onFrameChanged?() }
}
