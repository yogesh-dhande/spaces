import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// Alternate-screen reporting through the libghostty-vt shim and the bridge that turns a vt session
/// into a render snapshot. These drive a real vt session (the same calls the Linux headless daemon
/// and the client-local scrollback replay make), so they cover the C query and the Swift bridge
/// together. Clients route a scroll gesture on this flag: a session on the alternate screen has no
/// scrollback of its own, so the gesture belongs to the program rather than to a local viewport.
@Suite struct GhosttyVtAlternateScreenTests {
    private func makeSession(columns: UInt16 = 20, rows: UInt16 = 3) throws -> OpaquePointer {
        try #require(spaces_ghostty_vt_session_new(columns, rows, 0, nil))
    }

    private func write(_ session: OpaquePointer, _ text: String) {
        let data = Data(text.utf8)
        #expect(data.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })
    }

    private func snapshot(_ session: OpaquePointer) throws -> GhosttyTerminalSnapshot {
        var raw = SpacesGhosttyVtSnapshot()
        #expect(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        return GhosttyVtSessionBridge.snapshot(
            from: raw, mouseReportingActive: false, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session))
    }

    /// A fresh session is on the primary screen, mode 1049 moves it to the alternate screen, and
    /// leaving the mode moves it back. This is the sequence full-screen programs write on entry and
    /// exit, so it is exactly what a client's scroll routing has to follow.
    @Test func mode1049EntryAndExitMoveTheReportedScreen() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        #expect(try snapshot(session).alternateScreenActive == false)

        write(session, "\u{1B}[?1049h")
        #expect(try snapshot(session).alternateScreenActive == true)

        write(session, "\u{1B}[?1049l")
        #expect(try snapshot(session).alternateScreenActive == false)
    }

    /// Mode 1047 switches screens without the cursor save/restore of 1049. Reading the terminal's
    /// active screen rather than any single mode is what makes both spellings report alike.
    @Test func mode1047AlsoMovesTheReportedScreen() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "\u{1B}[?1047h")
        #expect(try snapshot(session).alternateScreenActive == true)

        write(session, "\u{1B}[?1047l")
        #expect(try snapshot(session).alternateScreenActive == false)
    }

    /// The flag describes the screen the exported cells came from: text printed after entering the
    /// alternate screen is what the snapshot shows, and the primary screen's text comes back on exit.
    @Test func theFlagMatchesTheScreenTheExportedCellsCameFrom() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }

        write(session, "primary")
        write(session, "\u{1B}[?1049h" + "alternate")
        let alternate = try snapshot(session)
        #expect(alternate.alternateScreenActive)
        #expect(GhosttyTerminalSnapshotLayout.plainText(for: alternate).contains("alternate"))
        #expect(!GhosttyTerminalSnapshotLayout.plainText(for: alternate).contains("primary"))

        write(session, "\u{1B}[?1049l")
        let primary = try snapshot(session)
        #expect(!primary.alternateScreenActive)
        #expect(GhosttyTerminalSnapshotLayout.plainText(for: primary).contains("primary"))
    }
}
