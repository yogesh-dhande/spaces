import Foundation
import XCTest
import spacesterminalcore

final class GhosttyRemoteSessionStateTests: XCTestCase {
    func testMergedPayloadCarriesIncrementalOutputBytesEphemerally() {
        let initial = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "initial", emittedAt: "2026-05-20T00:00:00Z", sessionStateRevision: 1, sessionStateFlags: 1,
            screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha",
            snapshot: snapshot(text: "alpha"), snapshotText: "alpha", transcriptTail: nil, outputByteCount: nil)

        let outputUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "output", emittedAt: "2026-05-20T00:00:01Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: nil, title: "alpha", workingDirectory: "/tmp/alpha", snapshot: nil,
            snapshotText: nil, transcriptTail: nil, outputByteCount: 2, outputData: Data("ls".utf8))

        let merged = initial.merged(with: outputUpdate)
        XCTAssertEqual(merged.snapshotText, "alpha")
        XCTAssertEqual(merged.snapshot?.columns, initial.snapshot?.columns)
        XCTAssertEqual(merged.outputByteCount, 2)
        XCTAssertEqual(merged.outputData, Data("ls".utf8))

        let metadataUpdate = GhosttyRemoteSessionStatePayload(
            sessionID: "session-1", reason: "attachment_state", emittedAt: "2026-05-20T00:00:02Z", sessionStateRevision: 2, sessionStateFlags: 1,
            screenStateRevision: 2, runtimeState: nil, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "alpha",
            workingDirectory: "/tmp/alpha", snapshot: nil, snapshotText: nil, transcriptTail: nil, outputByteCount: nil)

        let metadataMerged = merged.merged(with: metadataUpdate)
        XCTAssertNil(metadataMerged.outputData)
        XCTAssertEqual(metadataMerged.snapshotText, "alpha")
    }

    private func snapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }
}
