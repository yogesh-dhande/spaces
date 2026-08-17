import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

/// Why link activation is gated on an uncropped frame (#492).
///
/// Soft-wrap metadata is carried on every cell, so a column crop keeps each row's "wraps into the next
/// row" bit while the columns past the viewport's width are gone. Anything that reassembles a logical
/// line from a cropped frame — Ghostty's link hit-test joins wrapped rows exactly that way — therefore
/// reads a line built from each row's visible slice: a file path with its middle missing.
@Suite struct GhosttyTerminalSnapshotViewportWrappedLineTests {
    private static let hostColumns = 80
    private static let viewportColumns = 49
    private static let path = "/Users/yogesh/projects/spaces-ui-status-tabs/apps/macos/prototypes/status-tabs-command-palette/index.html"

    @Test func croppingASoftWrappedPathKeepsTheWrapBitsAndLosesTheColumnsBetweenThem() throws {
        let hostSnapshot = try softWrappedSnapshot(columns: Self.hostColumns, rows: 4, text: Self.path)
        #expect(Self.path.count > Self.hostColumns, "the fixture has to wrap on the host grid to say anything")
        #expect(joinedLogicalLine(from: hostSnapshot) == Self.path, "the host's own grid reassembles the complete path")

        let window = GhosttyTerminalSnapshotViewport.window(
            for: hostSnapshot, columns: Self.viewportColumns, rows: hostSnapshot.rows, horizontalAlignment: .leading)
        #expect(!GhosttyTerminalSnapshotViewport.covers(hostSnapshot, window: window))
        let cropped = GhosttyTerminalSnapshotViewport.crop(hostSnapshot, window: window)
        #expect(cropped.columns == Self.viewportColumns)

        let firstRowWraps = cropped.cells[0].flags & GhosttyTerminalSnapshotGrid.rowWrapFlag != 0
        #expect(firstRowWraps, "the crop drops columns but keeps the row's claim that it wraps into the next one")

        let corrupted = joinedLogicalLine(from: cropped)
        #expect(corrupted != Self.path)
        #expect(
            corrupted == String(Self.path.prefix(Self.viewportColumns)) + String(Self.path.dropFirst(Self.hostColumns)),
            "each wrapped row contributes only the columns the viewport kept, so the middle of the path is missing")
    }

    /// Once the owner runtime has resized to the phone's width the crop is the identity, and the same
    /// reassembly yields the complete path again.
    @Test func aGridThatFitsTheViewportReassemblesTheCompletePath() throws {
        let snapshot = try softWrappedSnapshot(columns: Self.viewportColumns, rows: 4, text: Self.path)
        let window = GhosttyTerminalSnapshotViewport.window(
            for: snapshot, columns: Self.viewportColumns, rows: snapshot.rows, horizontalAlignment: .leading)

        #expect(GhosttyTerminalSnapshotViewport.covers(snapshot, window: window))
        #expect(joinedLogicalLine(from: GhosttyTerminalSnapshotViewport.crop(snapshot, window: window)) == Self.path)
    }

    /// Produces the row flags through the real vt export path rather than synthesizing them, so the test
    /// reads the same metadata a mirrored frame carries.
    private func softWrappedSnapshot(columns: Int, rows: Int, text: String) throws -> GhosttyTerminalSnapshot {
        let session = try #require(spaces_ghostty_vt_session_new(UInt16(columns), UInt16(rows), 0, nil))
        defer { spaces_ghostty_vt_session_free(session) }
        let output = Data(text.utf8)
        #expect(output.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })

        var raw = SpacesGhosttyVtSnapshot()
        #expect(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        return GhosttyVtSessionBridge.snapshot(from: raw, mouseReportingActive: false)
    }

    /// Reassembles the logical line starting at row 0 the way a wrapped-line selection does: keep taking
    /// rows while the current row is flagged as wrapping into the next. The wrap bit is read from the
    /// row's first cell, which is where the mirror's snapshot applier reads it.
    private func joinedLogicalLine(from snapshot: GhosttyTerminalSnapshot) -> String {
        var joined = ""
        var row = 0
        while row < snapshot.rows {
            joined += rowText(snapshot, row: row)
            guard snapshot.cells[row * snapshot.columns].flags & GhosttyTerminalSnapshotGrid.rowWrapFlag != 0 else { break }
            row += 1
        }
        return joined
    }

    private func rowText(_ snapshot: GhosttyTerminalSnapshot, row: Int) -> String {
        let start = row * snapshot.columns
        var scalars = snapshot.cells[start..<(start + snapshot.columns)].map { cell in UnicodeScalar(cell.codepoint == 0 ? 32 : cell.codepoint) ?? " "
        }
        while let last = scalars.last, last == " " { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}
