import AppKit
import Testing

@testable import spacesui

@MainActor private final class FakePaneContent: PaneContentHosting {
    let descriptor: PaneContentDescriptor
    let contentView = NSView()
    let displayTitle: String
    var onTitleChanged: ((String) -> Void)?

    init(sessionID: String, accessibilityIdentifier: String) {
        descriptor = .terminalSession(deviceID: "device", sessionID: sessionID)
        displayTitle = sessionID
        contentView.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    func activate(focus _: Bool) {}
    func deactivate() {}
    func close() {}
    func makeContentFirstResponder() -> Bool { false }
    func owns(responder: NSResponder) -> Bool { responder === contentView }
    func handleKeyEvent(_: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_: NSEvent) -> Bool { false }
}

@MainActor @Suite struct PaneViewContentTests {
    private func identifiers(in root: NSView) -> [String] {
        var values: [String] = []
        func walk(_ view: NSView) {
            let identifier = view.accessibilityIdentifier()
            if !identifier.isEmpty { values.append(identifier) }
            for subview in view.subviews { walk(subview) }
        }
        walk(root)
        return values
    }

    @Test func replacingPaneContentRemovesPreviousContentView() {
        let pane = PaneView(paneID: "pane-1")
        let first = FakePaneContent(sessionID: "session-1", accessibilityIdentifier: "first-content")
        let second = FakePaneContent(sessionID: "session-1", accessibilityIdentifier: "second-content")

        pane.attachContent(first)
        #expect(identifiers(in: pane).contains("first-content"))

        pane.attachContent(second)

        let renderedIdentifiers = identifiers(in: pane)
        #expect(!renderedIdentifiers.contains("first-content"))
        #expect(renderedIdentifiers.contains("second-content"))
    }
}
