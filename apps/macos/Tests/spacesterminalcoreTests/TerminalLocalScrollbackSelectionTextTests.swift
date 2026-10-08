import Foundation
import Testing

@testable import spacesterminalcore

/// Reading a client's selection back out of its transcript replay, in the host's absolute rows.
@Suite struct TerminalLocalScrollbackSelectionTextTests {
    private let columns = 20
    private let rows = 6
    private let identity = HostTerminalSimulator.fileIdentity
    private let lineBytes = HostTranscript.lineByteCount
    /// Numbered lines in the file. A 20-column host prunes only after several thousand, and the stamp is
    /// taken past that so the host's absolute rows run ahead of anything the suffix replay counts itself.
    private let fileLines = 8800
    private let stampLines = 8500
    private let cutLines = 3000

    private var theme: GhosttyThemeExport {
        GhosttyThemeExport(
            background: ThemeColor(0, 0, 0), foreground: ThemeColor(255, 255, 255), cursorColor: ThemeColor(200, 200, 200),
            cursorText: ThemeColor(0, 0, 0), selectionBackground: ThemeColor(50, 50, 50), selectionForeground: ThemeColor(255, 255, 255),
            palette: (0..<16).map { ThemeColor($0 * 8, $0 * 8, $0 * 8) })
    }

    private func makeModel(transcript: Data, start: UInt64 = 0, end: UInt64? = nil, stamps: [TerminalLiveFrameStamp] = []) throws
        -> TerminalLocalScrollbackModel
    {
        try #require(
            TerminalLocalScrollbackModel(
                columns: columns, rows: rows, theme: theme, appearance: .dark, transcript: transcript, transcriptStartByteOffset: start,
                transcriptEndByteOffset: end ?? (start + UInt64(transcript.count)), requestedByteCount: transcript.count,
                transcriptFileIdentity: identity, runIdentity: nil, stamps: stamps))
    }

    private func cell(_ column: Int, _ row: Int64) -> TerminalAbsoluteCell { TerminalAbsoluteCell(column: column, row: row) }

    /// Lines 1...`fileLines`, then a 30-character line that soft-wraps at 20 columns (absolute rows
    /// `fileLines` and `fileLines + 1`), then a line with trailing blanks (absolute row `fileLines + 2`).
    /// The replay is a suffix cut after `cutLines` lines, so its own rows differ from the host's absolute
    /// rows, and a host stamp past the host's first prune aligns it.
    private func makeSuffixModel() throws -> (model: TerminalLocalScrollbackModel, epoch: UInt64) {
        let wrapped = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"
        let file = HostTranscript.lines(1...fileLines) + Data((wrapped + "\r\npadded   \r\n").utf8)
        let cut = cutLines * lineBytes
        let served =
            HostTerminalSimulator.statePreamble(afterWriting: file.prefix(cut), columns: columns, rows: rows) + file.subdata(in: cut..<file.count)
        let host = HostTerminalSimulator(columns: columns, rows: rows)
        host.write(file.prefix(stampLines * lineBytes))
        try #require(host.position.rows_pruned > 0)
        let stamp = host.stamp()
        let model = try makeModel(transcript: served, start: UInt64(cut), end: UInt64(file.count), stamps: [stamp])
        return (model, stamp.historyEpoch)
    }

    @Test func aSelectionSpanningReplayScrollbackAndTheActiveAreaReadsFromTheReplay() throws {
        let (model, epoch) = try makeSuffixModel()
        let last = Int64(fileLines)
        let selection = TerminalAbsoluteSelection(from: cell(0, last - 3), to: cell(8, last + 2), isRectangle: false, historyEpoch: epoch)

        let text = try #require(model.text(for: selection))

        #expect(
            text
                == [
                    HostTranscript.line(fileLines - 2), HostTranscript.line(fileLines - 1), HostTranscript.line(fileLines),
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123", "padded",
                ].joined(separator: "\n"))
    }

    @Test func aRectangleReadsItsColumnBandFromEachRow() throws {
        let (model, epoch) = try makeSuffixModel()
        let selection = TerminalAbsoluteSelection(from: cell(9, 8647), to: cell(6, 8649), isRectangle: true, historyEpoch: epoch)

        #expect(model.text(for: selection) == "8648\n8649\n8650")
    }

    @Test func aSelectionFromAnotherEpochReadsNothing() throws {
        let (model, epoch) = try makeSuffixModel()
        let selection = TerminalAbsoluteSelection(
            from: cell(0, Int64(fileLines) - 3), to: cell(8, Int64(fileLines) + 2), isRectangle: false, historyEpoch: epoch &+ 1)

        #expect(model.text(for: selection) == nil)
    }

    @Test func rowsOlderThanTheReplayHoldsAreClippedOffTheStart() throws {
        let (model, epoch) = try makeSuffixModel()
        let oldest = model.oldestAbsoluteRow
        #expect(oldest > 10)
        let throughCut = Int64(cutLines)
        let selection = TerminalAbsoluteSelection(from: cell(4, 10), to: cell(9, throughCut), isRectangle: false, historyEpoch: epoch)

        let text = try #require(model.text(for: selection))

        #expect(text.hasSuffix(HostTranscript.line(cutLines + 1)))
        #expect(HostTranscript.lineNumber(String(text.split(separator: "\n").first ?? "")) == Int(oldest) + 1)
        #expect(model.text(for: TerminalAbsoluteSelection(from: cell(0, 1), to: cell(5, 2), isRectangle: false, historyEpoch: epoch)) == nil)
    }

    @Test func selectAllCoversTheFirstToTheLastNonBlankCell() throws {
        let file = Data("   indent\r\nmiddle\r\n\r\ntail   \r\n\r\n".utf8)
        let host = HostTerminalSimulator(columns: columns, rows: rows)
        host.write(file)
        let hostStamp = host.stamp()
        let stamp = TerminalLiveFrameStamp(
            transcriptByteOffset: hostStamp.transcriptByteOffset, transcriptFileIdentity: identity, historyEpoch: 0xE,
            activeTopRow: hostStamp.activeTopRow, columns: columns, rows: rows)
        let model = try makeModel(transcript: file, stamps: [stamp])

        let selection = try #require(model.selectAllSelection())

        #expect(selection.start == cell(3, 0))
        #expect(selection.end == cell(3, 3))
        #expect(!selection.isRectangle)
        #expect(selection.historyEpoch == 0xE)
        #expect(model.text(for: selection) == "indent\nmiddle\n\ntail")
    }

    @Test func selectAllSpansScrollbackInHostRows() throws {
        let (model, epoch) = try makeSuffixModel()

        let selection = try #require(model.selectAllSelection())

        #expect(selection.historyEpoch == epoch)
        #expect(selection.start.row == model.oldestAbsoluteRow)
        #expect(selection.end == cell(5, Int64(fileLines) + 2))
    }

    @Test func selectAllOfAReplayWithNoTextIsNil() throws {
        let model = try makeModel(transcript: Data("\r\n\r\n".utf8))

        #expect(model.selectAllSelection() == nil)
    }
}
