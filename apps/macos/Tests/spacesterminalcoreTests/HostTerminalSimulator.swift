import Foundation
import ghosttyvtshim

@testable import spacesterminalcore

/// A stand-in for a host's terminal: a libghostty-vt session with a small scrollback limit, so it prunes
/// the way a long-running host does, fed the same bytes a client's transcript replay is later fed. Tests
/// read the host's history position and frames at chosen byte offsets to build the stamps and expectations
/// a real host would have produced.
final class HostTerminalSimulator {
    static let fileIdentity: UInt64 = 7

    let columns: Int
    let rows: Int
    private let session: OpaquePointer
    private(set) var writtenByteCount: UInt64 = 0

    init(columns: Int, rows: Int, maxScrollbackBytes: Int = 1) {
        self.columns = columns
        self.rows = rows
        session = spaces_ghostty_vt_session_new(UInt16(columns), UInt16(rows), maxScrollbackBytes, nil)!
    }

    deinit { spaces_ghostty_vt_session_free(session) }

    func write(_ bytes: Data) {
        bytes.withUnsafeBytes { raw in _ = spaces_ghostty_vt_session_write(session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
        writtenByteCount += UInt64(bytes.count)
    }

    func scroll(deltaRows: Int) { _ = spaces_ghostty_vt_session_scroll_viewport(session, deltaRows) }

    var position: SpacesGhosttyVtHistoryPosition {
        var position = SpacesGhosttyVtHistoryPosition()
        precondition(spaces_ghostty_vt_session_history_position(session, &position))
        return position
    }

    /// The frame the host would export now, stamped with the transcript offset it has been fed.
    func frame(fileIdentity: UInt64 = HostTerminalSimulator.fileIdentity) -> GhosttyRenderFrame {
        var raw = SpacesGhosttyVtSnapshot()
        precondition(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        let position = self.position
        let snapshot = GhosttyVtSessionBridge.snapshot(
            from: raw, mouseTrackingLevel: .none, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session),
            scrollbarTotal: UInt32(position.total), scrollbarOffset: UInt32(position.offset), historyRowBase: position.rows_pruned + position.offset,
            historyEpoch: position.history_epoch)
        return GhosttyRenderFrame(
            sessionRevision: nil, ownerEpoch: 0, snapshot: snapshot, transcriptByteOffset: writtenByteCount, transcriptFileIdentity: fileIdentity)
    }

    var snapshot: GhosttyTerminalSnapshot { frame().snapshot }

    /// The stamp of the frame the host would export now.
    func stamp(fileIdentity: UInt64 = HostTerminalSimulator.fileIdentity) -> TerminalLiveFrameStamp {
        TerminalLiveFrameStamp(frame: frame(fileIdentity: fileIdentity))!
    }

    /// The state preamble a daemon serves in front of a suffix read cut after `prefix`.
    static func statePreamble(afterWriting prefix: Data, columns: Int, rows: Int) -> Data {
        let session = spaces_ghostty_vt_session_new(UInt16(columns), UInt16(rows), TerminalScrollbackBudget.defaultMaxBytes, nil)!
        defer { spaces_ghostty_vt_session_free(session) }
        prefix.withUnsafeBytes { raw in _ = spaces_ghostty_vt_session_write(session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        precondition(spaces_ghostty_vt_session_state_preamble(session, &pointer, &length))
        defer { spaces_ghostty_vt_free_buffer(pointer) }
        return Data(bytes: pointer!, count: length)
    }
}

enum HostTranscript {
    /// One numbered line, ten visible characters: "row-000123". Line `n` is written at absolute row `n - 1`
    /// when the host starts empty and never clears.
    static func line(_ number: Int) -> String { String(format: "row-%06d", number) }

    /// Lines `range` as CRLF-terminated bytes.
    static func lines(_ range: ClosedRange<Int>) -> Data { Data(range.map { line($0) + "\r\n" }.joined().utf8) }

    static let lineByteCount = 12

    /// Per-row text of a snapshot with trailing blanks trimmed.
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

    /// The line number a row shows, or nil for a row that is not a numbered line.
    static func lineNumber(_ text: String) -> Int? {
        guard text.count == 10, text.hasPrefix("row-") else { return nil }
        return Int(text.dropFirst(4))
    }
}
