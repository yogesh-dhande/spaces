import Foundation
import Testing
import ghosttyvtshim

@testable import spacesterminalcore

@Suite struct GhosttyVtSnapshotRowWrapTests {
    private let rowWrapFlag = GhosttyTerminalSnapshotGrid.rowWrapFlag
    private let rowWrapContinuationFlag = GhosttyTerminalSnapshotGrid.rowWrapContinuationFlag

    @Test func softWrappedRowsCarryMetadataThroughExportAndDeltaTransport() throws {
        let columns: UInt16 = 8
        let rows: UInt16 = 3
        let session = try #require(spaces_ghostty_vt_session_new(columns, rows, 0, nil))
        defer { spaces_ghostty_vt_session_free(session) }

        let output = Data("https://example.test".utf8)
        #expect(output.withUnsafeBytes { spaces_ghostty_vt_session_write(session, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) })

        let exported = try snapshot(from: session)
        let firstRow = Array(exported.cells[0..<Int(columns)])
        let secondRow = Array(exported.cells[Int(columns)..<(2 * Int(columns))])
        let thirdRow = Array(exported.cells[(2 * Int(columns))..<(3 * Int(columns))])
        #expect(firstRow.allSatisfy { $0.flags & rowWrapFlag != 0 })
        #expect(firstRow.allSatisfy { $0.flags & rowWrapContinuationFlag == 0 })
        #expect(secondRow.allSatisfy { $0.flags & rowWrapFlag != 0 })
        #expect(secondRow.allSatisfy { $0.flags & rowWrapContinuationFlag != 0 })
        #expect(thirdRow.allSatisfy { $0.flags & rowWrapContinuationFlag != 0 }, "trailing default-fill cells retain row continuation")
        #expect(thirdRow.allSatisfy { $0.flags & rowWrapFlag == 0 })

        let blank = GhosttyTerminalSnapshot(
            columns: Int(columns), rows: Int(rows), cursorColumn: 0, cursorRow: 0, cursorVisible: false,
            defaultForegroundRGB: exported.defaultForegroundRGB, defaultBackgroundRGB: exported.defaultBackgroundRGB,
            cells: Array(repeating: .init(codepoint: 0, foregroundRGB: exported.defaultForegroundRGB, backgroundRGB: exported.defaultBackgroundRGB, flags: 0),
                         count: Int(columns) * Int(rows)))
        let baseline = GhosttyRenderUpdateBaseline(snapshot: blank, sessionRevision: 1, ownerEpoch: 1)
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: exported)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))
        let applied = try GhosttyRenderUpdateApplier.apply(decoded, to: baseline)

        #expect(applied.snapshot == exported)
        #expect(applied.snapshot.cells[Int(columns) - 1].flags & rowWrapFlag != 0, "row wrap survives delta transport")
        #expect(applied.snapshot.cells[3 * Int(columns) - 1].flags & rowWrapContinuationFlag != 0, "trailing default-fill cell retains row continuation")
    }

    private func snapshot(from session: OpaquePointer) throws -> GhosttyTerminalSnapshot {
        var raw = SpacesGhosttyVtSnapshot()
        #expect(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        return GhosttyVtSessionBridge.snapshot(from: raw, mouseReportingActive: false)
    }
}
