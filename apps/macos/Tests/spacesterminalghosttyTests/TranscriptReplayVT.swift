import Foundation
import ghosttyvtshim
import spacesterminalcore

/// An exported full frame as the stamp tests read it: the picture's own fields (`snapshot`) next to the
/// frame-level transcript stamp.
struct TranscriptFrame {
    let frame: GhosttyRenderFrame
    var snapshot: GhosttyTerminalSnapshot { frame.snapshot }
    var columns: Int { snapshot.columns }
    var rows: Int { snapshot.rows }
    var scrollbarOffset: UInt32 { snapshot.scrollbarOffset }
    var historyRowBase: UInt64 { snapshot.historyRowBase }
    var historyEpoch: UInt64 { snapshot.historyEpoch }
    var transcriptByteOffset: UInt64 { frame.transcriptByteOffset }
    var transcriptFileIdentity: UInt64 { frame.transcriptFileIdentity }
}

extension GhosttyRemoteSessionStatePayload { var transcriptFrame: TranscriptFrame? { decodedRenderUpdate?.fullFrame.map(TranscriptFrame.init) } }

/// Replays transcript bytes into a fresh libghostty-vt terminal, the way a client rebuilds a session's
/// screen from `output.log`, so a host test can check that a frame's `transcriptByteOffset` names a
/// transcript prefix that reproduces the frame's grid.
enum TranscriptReplayVT {
    /// The visible rows of a `columns` x `rows` terminal after `bytes` were written to it.
    static func screenRows(columns: Int, rows: Int, bytes: Data) -> [String] {
        let session = spaces_ghostty_vt_session_new(UInt16(columns), UInt16(rows), TerminalScrollbackBudget.defaultMaxBytes, nil)!
        defer { spaces_ghostty_vt_session_free(session) }
        bytes.withUnsafeBytes { raw in _ = spaces_ghostty_vt_session_write(session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
        var raw = SpacesGhosttyVtSnapshot()
        precondition(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        return rowTexts(
            GhosttyVtSessionBridge.snapshot(
                from: raw, mouseTrackingLevel: .none, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session)))
    }

    static func rowTexts(_ frame: TranscriptFrame) -> [String] { rowTexts(frame.snapshot) }

    /// Per-row text of a snapshot with trailing blanks trimmed and spacer cells skipped.
    static func rowTexts(_ snapshot: GhosttyTerminalSnapshot) -> [String] {
        (0..<snapshot.rows).map { row -> String in
            var text = ""
            for column in 0..<snapshot.columns {
                let index = row * snapshot.columns + column
                let cell = snapshot.cells[index]
                guard cell.flags & GhosttyTerminalSnapshotGrid.spacerFlag == 0 else { continue }
                text += snapshot.clusters[index] ?? (cell.codepoint == 0 ? " " : String(UnicodeScalar(cell.codepoint) ?? " "))
            }
            return text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    /// The first `length` bytes of the file at `path`, or nil while the file is still shorter than that.
    static func prefix(ofFileAt path: String, length: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= length else { return nil }
        try? handle.seek(toOffset: 0)
        return try? handle.read(upToCount: Int(length)) ?? Data()
    }

    /// The identity `TerminalTranscriptFileIdentity` reports for the file currently at `path`.
    static func fileIdentity(ofFileAt path: String) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? TerminalTranscriptFileIdentity.of(handle)
    }

    /// One marker line: unique, fixed width, so row k of a flood is recognisable and its byte position is
    /// arithmetic (`wireWidth` bytes a line once the tty adds CR).
    static let markerWidth = 40
    static let wireWidth = markerWidth + 2

    static func marker(_ number: Int) -> String {
        let head = String(format: "marker-%06d-", number)
        return head + String(repeating: "x", count: markerWidth - head.count)
    }

    /// The marker number a row shows, or nil for a blank, partial, or non-marker row.
    static func markerNumber(_ text: String) -> Int? {
        guard text.count == markerWidth, text.hasPrefix("marker-") else { return nil }
        return Int(text.dropFirst(7).prefix(6))
    }
}
