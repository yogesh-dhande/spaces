import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// OSC 8 hyperlinks through the libghostty-vt snapshot export and the bridge that turns it into render
/// cells. These drive a real vt session through the shim, the call the Linux headless daemon and the
/// client-local scrollback replay both make, so a link a program prints reaches the render snapshot with
/// its target: the render-state iterator exposes no hyperlink, so the export reads each linked cell's
/// target separately.
@Suite struct GhosttyVtSnapshotHyperlinkTests {
    private static let escape = "\u{1B}"
    private static let terminator = "\u{1B}\\"

    private func makeSession(columns: UInt16 = 40, rows: UInt16 = 3) throws -> OpaquePointer {
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
        let snapshot = GhosttyVtSessionBridge.snapshot(from: raw, mouseTrackingLevel: .none, alternateScreenActive: false)
        try #require(snapshot.columns > 0)
        return snapshot
    }

    private func link(_ target: String, label: String) -> String {
        "\(Self.escape)]8;;\(target)\(Self.terminator)\(label)\(Self.escape)]8;;\(Self.terminator)"
    }

    /// A label that is not its target keeps the target on every cell of the label, and the cells around
    /// it carry none.
    @Test func linkedLabelCarriesItsTargetOnEachOfItsCells() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "go " + link("https://example.com/docs", label: "Docs") + " now")

        let snapshot = try snapshot(session)
        #expect(snapshot.linkURLs[2] == nil)
        for column in 3...6 { #expect(snapshot.linkURLs[column] == "https://example.com/docs", "column \(column)") }
        #expect(snapshot.linkURLs[7] == nil)
        #expect(snapshot.linkURLs.count == 4)
    }

    @Test func differentTargetsStayDistinctAndTheSameTargetRepeats() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(
            session, link("https://a.example", label: "A") + " " + link("https://b.example", label: "B") + " " + link("https://a.example", label: "C")
        )

        let snapshot = try snapshot(session)
        #expect(snapshot.linkURLs[0] == "https://a.example")
        #expect(snapshot.linkURLs[2] == "https://b.example")
        #expect(snapshot.linkURLs[4] == "https://a.example")
        #expect(snapshot.linkURLs[1] == nil)
    }

    @Test func linkWithAnExplicitIdKeepsItsTarget() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "\(Self.escape)]8;id=docs;https://example.com/docs\(Self.terminator)Docs\(Self.escape)]8;;\(Self.terminator)")

        #expect(try snapshot(session).linkURLs[0] == "https://example.com/docs")
    }

    @Test func frameWithoutLinksCarriesNone() throws {
        let session = try makeSession()
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, "plain text")

        #expect(try snapshot(session).linkURLs.isEmpty)
    }

    /// A target longer than the snapshot's cap is exported without its link, as the render wire format
    /// refuses to carry it; the text itself still reads back.
    @Test func targetPastTheCapIsDroppedAndTheTextStays() throws {
        let session = try makeSession(columns: 40, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }
        let tooLong = "https://example.com/" + String(repeating: "x", count: GhosttyTerminalSnapshot.maximumLinkURLUTF8ByteCount)
        write(session, link(tooLong, label: "Long") + " " + link("https://example.com/ok", label: "Ok"))

        let snapshot = try snapshot(session)
        #expect(snapshot.linkURLs[0] == nil)
        #expect(snapshot.cells[0].codepoint == UInt32(Character("L").unicodeScalars.first!.value))
        #expect(snapshot.linkURLs[5] == "https://example.com/ok")
    }

    /// A link broken across rows by the terminal's own wrapping keeps its target on both rows.
    @Test func linkThatWrapsKeepsItsTargetOnEveryRow() throws {
        let session = try makeSession(columns: 8, rows: 3)
        defer { spaces_ghostty_vt_session_free(session) }
        write(session, link("https://example.com", label: "wrapped-label"))

        let snapshot = try snapshot(session)
        #expect(snapshot.linkURLs[0] == "https://example.com")
        #expect(snapshot.linkURLs[snapshot.columns] == "https://example.com")
    }
}
