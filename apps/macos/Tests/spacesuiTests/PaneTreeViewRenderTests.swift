import AppKit
import Testing

@testable import spacesui

/// A content view that can actually become first responder, unlike a plain `NSView`
/// (which always refuses). Needed so the focus-retention test isn't vacuous.
@MainActor private final class FocusableView: NSView { override var acceptsFirstResponder: Bool { true } }

@MainActor private final class FakePaneContent: PaneContentHosting {
    let descriptor: PaneContentDescriptor
    let focusableView = FocusableView()
    var contentView: NSView { focusableView }
    let displayTitle: String
    var onTitleChanged: ((String) -> Void)?

    init(sessionID: String) {
        descriptor = .terminalSession(deviceID: "device", sessionID: sessionID)
        displayTitle = sessionID
    }

    func activate(focus _: Bool) {}
    func deactivate() {}
    func close() {}
    func makeContentFirstResponder() -> Bool { focusableView.window?.makeFirstResponder(focusableView) ?? false }
    func owns(responder: NSResponder) -> Bool { responder === contentView }
    func handleKeyEvent(_: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_: NSEvent) -> Bool { false }
}

@MainActor @Suite struct PaneTreeViewRenderTests {
    private func pane(_ id: String) -> Pane { Pane(id: id, content: .terminalSession(deviceID: "device", sessionID: id)) }

    private func twoLeafSplit() -> PaneNode {
        .split(PaneSplit(id: "split-1", orientation: .horizontal, weights: [0.5, 0.5], children: [.leaf(pane("pane-1")), .leaf(pane("pane-2"))]))
    }

    private func threeLeafSplit() -> PaneNode {
        .split(
            PaneSplit(
                id: "split-1", orientation: .horizontal, weights: [1.0 / 3, 1.0 / 3, 1.0 / 3],
                children: [.leaf(pane("pane-1")), .leaf(pane("pane-2")), .leaf(pane("pane-3"))]))
    }

    private func makeWindow(hosting tree: PaneTreeView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(tree)
        return window
    }

    private func paneViews(in root: NSView) -> [PaneView] {
        var found: [PaneView] = []
        func walk(_ view: NSView) {
            if let paneView = view as? PaneView { found.append(paneView) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return found
    }

    @Test func keepsKeyboardFocusWhenOnlyPaneFocusChanges() {
        let tree = PaneTreeView()
        var contentByPaneID: [String: FakePaneContent] = [:]
        tree.onConfigurePane = { view, pane in
            let content = contentByPaneID[pane.id] ?? FakePaneContent(sessionID: pane.id)
            contentByPaneID[pane.id] = content
            view.attachContent(content)
        }
        let window = makeWindow(hosting: tree)

        tree.render(root: twoLeafSplit())

        let secondContentView = contentByPaneID["pane-2"]!.contentView
        let claimed = window.makeFirstResponder(secondContentView)
        #expect(claimed)
        #expect(window.firstResponder === secondContentView)

        // Re-render with the identical structure, as happens on a focus-only sync.
        tree.render(root: twoLeafSplit())

        #expect(window.firstResponder === secondContentView)
    }

    @Test func rebuildsHierarchyWhenStructureChanges() {
        let tree = PaneTreeView()
        let window = makeWindow(hosting: tree)
        defer { withExtendedLifetime(window) {} }

        tree.render(root: twoLeafSplit())
        let firstPaneViewBefore = paneViews(in: tree).first { $0.paneID == "pane-1" }
        #expect(paneViews(in: tree).map(\.paneID) == ["pane-1", "pane-2"])

        tree.render(root: threeLeafSplit())

        let idsAfter = paneViews(in: tree).map(\.paneID)
        #expect(idsAfter == ["pane-1", "pane-2", "pane-3"])

        // The surviving pane id keeps the same PaneView instance — that identity is what
        // protects the hosted Ghostty surface from being recreated on a structural change.
        let firstPaneViewAfter = paneViews(in: tree).first { $0.paneID == "pane-1" }
        #expect(firstPaneViewBefore != nil)
        #expect(firstPaneViewBefore === firstPaneViewAfter)
    }

    @Test func reconfiguresPanesOnEveryRender() {
        let tree = PaneTreeView()
        var configureCounts: [String: Int] = [:]
        tree.onConfigurePane = { _, pane in configureCounts[pane.id, default: 0] += 1 }
        let window = makeWindow(hosting: tree)
        defer { withExtendedLifetime(window) {} }

        tree.render(root: twoLeafSplit())
        #expect(configureCounts["pane-1"] == 1)
        #expect(configureCounts["pane-2"] == 1)

        // Same structure again: no hierarchy rebuild, but panes must still be reconfigured
        // so the focus accent bar (and other per-render state) stays current.
        tree.render(root: twoLeafSplit())
        #expect(configureCounts["pane-1"] == 2)
        #expect(configureCounts["pane-2"] == 2)
    }
}
