import Foundation
import ghosttyvtshim
import spacesterminalcore

/// A stand-in for a session host's terminal: a libghostty-vt session fed numbered lines, exporting the
/// frames a real host would, each stamped with the history position and the transcript offset that
/// reproduces it. A test serves `bytes` as the transcript, so the pane's replay and the live frames
/// describe the same history.
final class StampedHostTerminal: @unchecked Sendable {
    static let fileIdentity: UInt64 = 7

    let columns: Int
    let rows: Int
    private let session: OpaquePointer
    private let lock = NSLock()
    private var written = Data()

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        session = spaces_ghostty_vt_session_new(UInt16(columns), UInt16(rows), TerminalScrollbackBudget.defaultMaxBytes, nil)!
    }

    deinit { spaces_ghostty_vt_session_free(session) }

    /// One numbered line, ten visible characters: "row-000123".
    static func line(_ number: Int) -> String { String(format: "row-%06d", number) }

    /// Bytes per written line: ten characters and CRLF.
    static let lineByteCount = 12

    /// The line number a row shows, or nil for a row that is not a numbered line.
    static func lineNumber(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 10, trimmed.hasPrefix("row-") else { return nil }
        return Int(trimmed.dropFirst(4))
    }

    /// Appends lines `range` as CRLF-terminated output. Line `n` sits at absolute row `n - 1` while the
    /// host never prunes or clears.
    func writeLines(_ range: ClosedRange<Int>) {
        let bytes = Data(range.map { Self.line($0) + "\r\n" }.joined().utf8)
        bytes.withUnsafeBytes { raw in _ = spaces_ghostty_vt_session_write(session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
        lock.lock()
        written.append(bytes)
        lock.unlock()
    }

    /// Appends raw output (escape sequences), as a program would write it.
    func write(_ text: String) {
        let bytes = Data(text.utf8)
        bytes.withUnsafeBytes { raw in _ = spaces_ghostty_vt_session_write(session, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) }
        lock.lock()
        written.append(bytes)
        lock.unlock()
    }

    /// The tracking level frames report, which the vt session does not expose.
    var mouseTrackingLevel: TerminalMouseTrackingLevel = .none

    /// Everything the session has been fed, which is what the transcript file holds.
    var bytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    /// The frame the host would export now, stamped with the offset it has been fed.
    func frame(revision: UInt64) -> GhosttyRenderFrame {
        var raw = SpacesGhosttyVtSnapshot()
        precondition(spaces_ghostty_vt_session_copy_snapshot(session, &raw))
        defer { spaces_ghostty_vt_snapshot_free(&raw) }
        var position = SpacesGhosttyVtHistoryPosition()
        precondition(spaces_ghostty_vt_session_history_position(session, &position))
        let snapshot = GhosttyVtSessionBridge.snapshot(
            from: raw, mouseTrackingLevel: mouseTrackingLevel, alternateScreenActive: GhosttyVtSessionBridge.alternateScreenActive(session: session),
            scrollbarTotal: UInt32(position.total), scrollbarOffset: UInt32(position.offset), historyRowBase: position.rows_pruned + position.offset,
            historyEpoch: position.history_epoch)
        return GhosttyRenderFrame(
            sessionRevision: revision, ownerEpoch: 0, snapshot: snapshot, transcriptByteOffset: UInt64(bytes.count),
            transcriptFileIdentity: Self.fileIdentity)
    }

    /// Per-row text of the viewport the host would export now.
    func rowTexts() -> [String] { TranscriptReplayVT.rowTexts(frame(revision: 0).snapshot) }
}
