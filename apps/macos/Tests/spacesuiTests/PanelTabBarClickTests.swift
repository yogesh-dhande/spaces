import AppKit
import Testing

@testable import spacesui

/// Dispatches real mouse events through the window to prove tab-bar chrome is
/// actually clickable (selection, close, context menu) — regressions here render
/// fine but silently stop responding.
@MainActor @Suite struct PanelTabBarClickTests {
    private func makeBarInWindow() -> (bar: PanelTabBarView, window: NSWindow) {
        let bar = PanelTabBarView()
        bar.update(tabIDs: ["t1", "t2"], titlesByTabID: ["t1": "one", "t2": "two"], selectedTabID: "t1")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        window.contentView = content
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    private func tabItemView(withID id: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == "panel-tab-\(id)" { return root }
        for sub in root.subviews {
            if let found = tabItemView(withID: id, in: sub) { return found }
        }
        return nil
    }

    private func mouseEvent(_ type: NSEvent.EventType, at pointInWindow: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: pointInWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Clicking a tab anywhere — including directly over its title text — selects it:
    /// hit-testing must resolve to the tab item (not the title label, which would
    /// swallow the event), and the resolved view's mouseDown must select.
    @Test func clickingATabSelectsIt() throws {
        let (bar, window) = makeBarInWindow()
        var selected: String?
        bar.onSelectTab = { selected = $0 }
        let item = try #require(tabItemView(withID: "t2", in: bar))
        let inWindow = item.convert(NSPoint(x: item.bounds.midX, y: item.bounds.midY), to: nil)
        let content = try #require(window.contentView)
        let hit = try #require(content.hitTest(content.convert(inWindow, from: nil)))
        hit.mouseDown(with: mouseEvent(.leftMouseDown, at: inWindow, in: window))
        #expect(selected == "t2", "hit view was \(type(of: hit))")
    }

    /// The close glyph keeps its own hits (the tab-surface hit routing must not
    /// absorb it) and clicking it closes the tab.
    @Test func clickingCloseGlyphClosesTheTab() throws {
        let (bar, window) = makeBarInWindow()
        var closed: String?
        bar.onCloseTab = { closed = $0 }
        let item = try #require(tabItemView(withID: "t2", in: bar))
        let close = try #require(
            item.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        let inWindow = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        let content = try #require(window.contentView)
        let hit = try #require(content.hitTest(content.convert(inWindow, from: nil)))
        #expect(hit === close, "hit view was \(type(of: hit))")
        close.performClick(nil)
        #expect(closed == "t2")
    }

    /// In the main window the tab strip sits inside the hidden titlebar region, where
    /// a view that acts as a window-drag area never receives mouseDown — the click
    /// moves the window instead of selecting the tab.
    @Test func tabItemsAreNotWindowDragAreas() throws {
        let (bar, _) = makeBarInWindow()
        let item = try #require(tabItemView(withID: "t2", in: bar))
        #expect(!item.mouseDownCanMoveWindow)
    }

    /// Re-rendering with unchanged state must not recreate the tab item views —
    /// rebuild churn tears down transient chrome like the rename popover's anchor.
    @Test func unchangedUpdateKeepsTabItemViews() throws {
        let (bar, _) = makeBarInWindow()
        let itemBefore = try #require(tabItemView(withID: "t2", in: bar))
        bar.update(tabIDs: ["t1", "t2"], titlesByTabID: ["t1": "one", "t2": "two"], selectedTabID: "t1")
        let itemAfter = try #require(tabItemView(withID: "t2", in: bar))
        #expect(itemBefore === itemAfter)
        bar.update(tabIDs: ["t1", "t2"], titlesByTabID: ["t1": "one", "t2": "two"], selectedTabID: "t2")
        let itemAfterSelectionChange = try #require(tabItemView(withID: "t2", in: bar))
        #expect(itemBefore !== itemAfterSelectionChange)
    }

    /// The rename menu must come from whatever view hit-testing resolves for a
    /// right-click over the title text (the label must not claim the event).
    @Test func rightClickOverTitleOffersRenameMenu() throws {
        let (bar, window) = makeBarInWindow()
        let item = try #require(tabItemView(withID: "t2", in: bar))
        let inWindow = item.convert(NSPoint(x: item.bounds.midX, y: item.bounds.midY), to: nil)
        let content = try #require(window.contentView)
        let hit = try #require(content.hitTest(content.convert(inWindow, from: nil)))
        let menu = hit.menu(for: mouseEvent(.rightMouseDown, at: inWindow, in: window))
        #expect(menu?.items.contains { $0.title == "Rename Tab" } == true)
    }
}
