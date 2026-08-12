import AppKit
import Foundation
import GhosttyKit
import XCTest

@testable import spacesterminalghostty

/// Ghostty reports a surface action — a link click, a search result count, a find-bar open — with only
/// the surface pointer to say which pane it belongs to, so the app keys its handlers by that pointer.
/// Surface addresses are reused: a pane that frees its mirror and a pane that builds one can land on the
/// same address, and the pane that is going away tears down after the one that arrived has registered.
/// Its unregistration must take its own handler with it and nothing else.
@MainActor final class GhosttyMirrorActionHandlerRegistrationTests: XCTestCase {
    private var registeredTokens: [GhosttyMirrorActionHandlerToken] = []

    override func tearDown() {
        for token in registeredTokens { GhosttyMirrorAppService.shared.unregisterActionHandler(token) }
        registeredTokens = []
        super.tearDown()
    }

    func testUnregisteringADeadPanesHandlerLeavesTheLivePaneAtTheSameAddressAlone() {
        let service = GhosttyMirrorAppService.shared
        let surface = Self.surfaceAddress(0xFEED_0001)
        var deadPaneEvents: [GhosttyActionEvent] = []
        var livePaneEvents: [GhosttyActionEvent] = []

        let deadPaneToken = register(for: surface) { deadPaneEvents.append($0) }
        // The freed surface's address comes back to a pane that builds its mirror next.
        let livePaneToken = register(for: surface) { livePaneEvents.append($0) }

        // The pane that lost its surface tears down afterwards.
        service.unregisterActionHandler(deadPaneToken)
        service.handleAction(.mouseOverLink("https://example.com"), surfaceKey: UInt(bitPattern: surface))
        drainMainQueue()

        XCTAssertEqual(livePaneEvents, [.mouseOverLink("https://example.com")], "a dying pane's teardown removed the live pane's action handler")
        XCTAssertTrue(deadPaneEvents.isEmpty, "an unregistered handler still received events")

        service.unregisterActionHandler(livePaneToken)
        service.handleAction(.mouseOverLink("https://example.org"), surfaceKey: UInt(bitPattern: surface))
        drainMainQueue()

        XCTAssertEqual(livePaneEvents.count, 1, "a handler kept receiving events after its own registration was removed")
    }

    // MARK: - Harness

    @discardableResult private func register(for surface: UnsafeMutableRawPointer, handler: @escaping @MainActor (GhosttyActionEvent) -> Void)
        -> GhosttyMirrorActionHandlerToken
    {
        let token = GhosttyMirrorAppService.shared.registerActionHandler(for: surface, handler: handler)
        registeredTokens.append(token)
        return token
    }

    /// Stands in for a Ghostty surface pointer. Registration keys and unregisters on the address alone
    /// and never dereferences it, which is exactly the property under test: two registrations here share
    /// one address the way a freed and a freshly allocated surface do.
    private static func surfaceAddress(_ value: UInt) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(bitPattern: value)! }

    private func drainMainQueue() {
        var drained = false
        Task { @MainActor in drained = true }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !drained { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(drained, "the main queue did not drain")
    }
}
