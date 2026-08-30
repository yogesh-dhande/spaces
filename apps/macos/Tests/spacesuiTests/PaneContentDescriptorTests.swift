import Foundation
import Testing

@testable import spacesui

/// `PaneContentDescriptor` is a plain synthesized-Codable enum (no custom `CodingKeys`), so adding
/// `.codePane` must not disturb how a `.terminalSession` case round-trips, and a layout persisted before
/// `.codePane` existed must still decode. Both properties are load-bearing for the panel document, which
/// is read back from the client DB at every launch.
@Suite struct PaneContentDescriptorTests {
    @Test func terminalSessionRoundTripsThroughCodable() throws {
        let descriptor = PaneContentDescriptor.terminalSession(deviceID: "device-1", sessionID: "session-1")

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(PaneContentDescriptor.self, from: data)

        #expect(decoded == descriptor)
        #expect(decoded.terminalSessionID == "session-1")
    }

    @Test func codePaneRoundTripsThroughCodable() throws {
        let descriptor = PaneContentDescriptor.codePane(deviceID: "device-1", workspaceID: "workspace-1")

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(PaneContentDescriptor.self, from: data)

        #expect(decoded == descriptor)
        #expect(decoded.terminalSessionID == nil, "a code pane has no session of its own")
    }

    /// A literal v1 layout carrying only the `.terminalSession` case — exactly what a client built
    /// before `.codePane` existed would have persisted — must still decode after the case was added.
    /// Captured by hand-encoding the same shape with a standalone reproduction of these types (the
    /// synthesized encoder wraps an unlabeled single-associated-value case, `PaneNode.leaf`, under an
    /// `"_0"` key), so this is what today's decoder is asked to read back, not something round-tripped
    /// through the current encoder.
    @Test func decodesAPersistedV1TerminalOnlyLayout() throws {
        let oldJSON = """
            {"version":1,"tabs":[{"id":"tab-1","root":{"leaf":{"_0":{"id":"a",\
            "content":{"terminalSession":{"deviceID":"device-1","sessionID":"session-1"}}}}}}],\
            "selectedTabID":"tab-1","focusedPaneID":"a"}
            """

        let layout = try JSONDecoder().decode(PanelLayout.self, from: Data(oldJSON.utf8))

        #expect(layout.version == 1)
        #expect(layout.selectedTabID == "tab-1")
        #expect(layout.focusedPaneID == "a")
        guard case .leaf(let pane) = layout.tabs.first?.root else {
            Issue.record("expected a leaf pane")
            return
        }
        #expect(pane.id == "a")
        #expect(pane.content == .terminalSession(deviceID: "device-1", sessionID: "session-1"))
    }
}
