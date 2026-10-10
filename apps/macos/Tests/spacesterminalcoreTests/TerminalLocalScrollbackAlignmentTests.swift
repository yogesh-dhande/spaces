import Foundation
import Testing

@testable import spacesterminalcore

/// The scrollback replay's rows, lined up with a host's absolute rows at a live frame stamp. The host is
/// a real libghostty-vt session with the smallest scrollback limit, fed the same numbered lines the replay
/// is built from; a 20-column terminal prunes only after several thousand lines, so the files here are long
/// enough for the host's absolute rows to run ahead of anything the replay counts for itself.
@Suite struct TerminalLocalScrollbackAlignmentTests {
    private let columns = 20
    private let rows = 6
    private let identity = HostTerminalSimulator.fileIdentity
    private let lineBytes = HostTranscript.lineByteCount
    /// Lines in the whole file, and where the host is when a stamp is taken (past its first prune).
    private let fileLines = 9000
    private let stampLines = 8500
    /// Where a suffix read is cut.
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

    private func makeHost(writing bytes: Data, requirePruned: Bool = true) throws -> HostTerminalSimulator {
        let host = HostTerminalSimulator(columns: columns, rows: rows)
        host.write(bytes)
        if requirePruned { try #require(host.position.rows_pruned > 0, "the host must have pruned for its absolute rows to differ from a replay's") }
        return host
    }

    /// What a suffix read of `file` cut after `cutLines` lines serves: a state preamble, then the file's
    /// bytes from the cut.
    private func suffixRead(of file: Data, through end: Int? = nil) -> Data {
        let cut = cutLines * lineBytes
        let preamble = HostTerminalSimulator.statePreamble(afterWriting: file.prefix(cut), columns: columns, rows: rows)
        return preamble + file.subdata(in: cut..<(end ?? file.count))
    }

    private func epochOverride(_ stamp: TerminalLiveFrameStamp, _ epoch: UInt64) -> TerminalLiveFrameStamp {
        TerminalLiveFrameStamp(
            transcriptByteOffset: stamp.transcriptByteOffset, transcriptFileIdentity: stamp.transcriptFileIdentity, historyEpoch: epoch,
            activeTopRow: stamp.activeTopRow, columns: stamp.columns, rows: stamp.rows)
    }

    /// Every numbered row of `snapshot` sits at the absolute row its `historyRowBase` names: line `n` was
    /// written at absolute row `n - 1`, and the first row must be a numbered line so the check says
    /// something.
    private func expectRowsNamedByBase(_ snapshot: GhosttyTerminalSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        let texts = HostTranscript.rowTexts(snapshot)
        #expect(
            HostTranscript.lineNumber(texts[0]) == Int(snapshot.historyRowBase) + 1, "row 0 of \(texts) with base \(snapshot.historyRowBase)",
            sourceLocation: sourceLocation)
        for (row, text) in texts.enumerated() {
            guard let number = HostTranscript.lineNumber(text) else { continue }
            #expect(number == Int(snapshot.historyRowBase) + row + 1, sourceLocation: sourceLocation)
        }
    }

    private func expectNamedByBaseAtSeveralScrollPositions(_ model: TerminalLocalScrollbackModel, sourceLocation: SourceLocation = #_sourceLocation) {
        for delta in [0, -7, -60, -400, -100_000] {
            let snapshot = model.scroll(deltaRows: delta).snapshot ?? model.currentSnapshot()
            expectRowsNamedByBase(snapshot, sourceLocation: sourceLocation)
        }
    }

    // MARK: - Stamps

    @Test func stampActiveTopDoesNotDependOnWhereTheHostViewportIsScrolled() throws {
        let host = try makeHost(writing: HostTranscript.lines(1...fileLines))
        let atBottom = host.stamp()
        host.scroll(deltaRows: -9)
        #expect(host.stamp() == atBottom)
        #expect(atBottom.activeTopRow == Int64(host.position.rows_pruned + host.position.total) - Int64(rows))
    }

    @Test func aFrameWithoutATranscriptIdentityHasNoStamp() throws {
        let host = try makeHost(writing: HostTranscript.lines(1...fileLines))
        #expect(TerminalLiveFrameStamp(frame: host.frame(fileIdentity: 0)) == nil)
    }

    @Test func theStampRingKeepsTheNewestStampsAndSkipsARepeatedOne() {
        var ring = TerminalLiveFrameStampRing()
        for offset in 0..<UInt64(TerminalLiveFrameStampRing.capacity + 10) {
            let stamp = TerminalLiveFrameStamp(
                transcriptByteOffset: offset, transcriptFileIdentity: 1, historyEpoch: 1, activeTopRow: 0, columns: 20, rows: 6)
            ring.record(stamp)
            ring.record(stamp)
        }
        #expect(ring.stamps.count == TerminalLiveFrameStampRing.capacity)
        #expect(ring.stamps.first?.transcriptByteOffset == 10)
        #expect(ring.stamps.last?.transcriptByteOffset == UInt64(TerminalLiveFrameStampRing.capacity + 9))
    }

    // MARK: - Whole-file build

    @Test func aWholeFileReplayReportsTheHostsRowsAndEpochAtEveryScrollPosition() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = try makeHost(writing: file.prefix(stampLines * lineBytes))
        let stamp = epochOverride(host.stamp(), 0xABC)

        let model = try makeModel(transcript: file, stamps: [stamp])

        #expect(model.currentSnapshot().historyEpoch == 0xABC)
        #expect(model.historyEpoch == 0xABC)
        expectNamedByBaseAtSeveralScrollPositions(model)
        #expect(model.currentSnapshot().historyEpoch == 0xABC)
    }

    @Test func theLatestStampInsideTheBytesWins() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = HostTerminalSimulator(columns: columns, rows: rows)
        host.write(file.prefix(stampLines * lineBytes))
        let early = epochOverride(host.stamp(), 1)
        host.write(file.subdata(in: stampLines * lineBytes..<(stampLines + 100) * lineBytes))
        let late = epochOverride(host.stamp(), 2)

        // Arrival order must not matter: the stamp with the larger offset wins.
        let model = try makeModel(transcript: file, stamps: [late, early])

        expectRowsNamedByBase(model.currentSnapshot())
        #expect(model.currentSnapshot().historyEpoch == 2)
    }

    // MARK: - Suffix build with a preamble

    @Test func aSuffixReplayAlignsPastItsStatePreamble() throws {
        let file = HostTranscript.lines(1...fileLines)
        let served = suffixRead(of: file)
        let host = try makeHost(writing: file.prefix(stampLines * lineBytes))
        let stamp = host.stamp()
        let cut = UInt64(cutLines * lineBytes)

        let unaligned = try makeModel(transcript: served, start: cut, end: UInt64(file.count))
        let model = try makeModel(transcript: served, start: cut, end: UInt64(file.count), stamps: [stamp])

        let unalignedSnapshot = unaligned.currentSnapshot()
        #expect(unalignedSnapshot.historyEpoch != stamp.historyEpoch)
        #expect(
            HostTranscript.lineNumber(HostTranscript.rowTexts(unalignedSnapshot)[0]) != Int(unalignedSnapshot.historyRowBase) + 1,
            "without a stamp the replay counts from its preamble")
        #expect(model.currentSnapshot().historyEpoch == stamp.historyEpoch)
        expectNamedByBaseAtSeveralScrollPositions(model)
    }

    @Test func aStampExactlyAtTheStartOffsetAlignsAfterThePreamble() throws {
        let file = HostTranscript.lines(1...fileLines)
        let served = suffixRead(of: file)
        let host = try makeHost(writing: file.prefix(cutLines * lineBytes), requirePruned: false)
        let stamp = host.stamp()
        #expect(stamp.transcriptByteOffset == UInt64(cutLines * lineBytes))

        let model = try makeModel(transcript: served, start: stamp.transcriptByteOffset, end: UInt64(file.count), stamps: [stamp])

        #expect(model.currentSnapshot().historyEpoch == stamp.historyEpoch)
        expectNamedByBaseAtSeveralScrollPositions(model)
    }

    @Test func aStampAtTheEndOfTheBytesAlignsToTheHostsOwnFrame() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = try makeHost(writing: file)
        let stamp = host.stamp()

        let model = try makeModel(transcript: suffixRead(of: file), start: UInt64(cutLines * lineBytes), end: UInt64(file.count), stamps: [stamp])

        let hostFrame = host.snapshot
        let replayFrame = model.currentSnapshot()
        #expect(replayFrame.historyRowBase == hostFrame.historyRowBase)
        #expect(replayFrame.historyEpoch == hostFrame.historyEpoch)
        #expect(HostTranscript.rowTexts(replayFrame) == HostTranscript.rowTexts(hostFrame))
    }

    // MARK: - No stamp, wrong stamp

    @Test func withoutAStampInRangeTheReplayKeepsItsOwnNumberingUntilALaterAppendAligns() throws {
        let file = HostTranscript.lines(1...fileLines)
        let readLines = 5000
        let host = try makeHost(writing: file.prefix(stampLines * lineBytes))
        let stamp = host.stamp()
        let outsideBefore = TerminalLiveFrameStamp(
            transcriptByteOffset: 5 * UInt64(lineBytes), transcriptFileIdentity: identity, historyEpoch: 9, activeTopRow: 0, columns: columns,
            rows: rows)
        let outsideAfter = TerminalLiveFrameStamp(
            transcriptByteOffset: UInt64(file.count) * 2, transcriptFileIdentity: identity, historyEpoch: 9, activeTopRow: 0, columns: columns,
            rows: rows)

        let model = try makeModel(
            transcript: suffixRead(of: file, through: readLines * lineBytes), start: UInt64(cutLines * lineBytes), end: UInt64(readLines * lineBytes),
            stamps: [outsideBefore, outsideAfter])
        let unalignedSnapshot = model.currentSnapshot()
        #expect(unalignedSnapshot.historyEpoch != 9 && unalignedSnapshot.historyEpoch != stamp.historyEpoch)
        #expect(
            HostTranscript.lineNumber(HostTranscript.rowTexts(unalignedSnapshot)[0]) != Int(unalignedSnapshot.historyRowBase) + 1,
            "the replay counts from its preamble, not from the host's row 0")

        let appended = file.subdata(in: readLines * lineBytes..<file.count)
        #expect(model.append(appended, transcriptEndByteOffset: UInt64(file.count), stamps: [stamp]))

        #expect(model.currentSnapshot().historyEpoch == stamp.historyEpoch)
        expectNamedByBaseAtSeveralScrollPositions(model)
    }

    @Test func aStampAtTheCurrentEndIsNotInTheAppendedRange() throws {
        let file = HostTranscript.lines(1...fileLines)
        let first = file.prefix(stampLines * lineBytes)
        let host = try makeHost(writing: first)
        let stampAtEnd = host.stamp()
        let model = try makeModel(transcript: Data(first))
        let ownEpoch = model.historyEpoch

        #expect(model.append(file.suffix(from: stampLines * lineBytes), transcriptEndByteOffset: UInt64(file.count), stamps: [stampAtEnd]))

        #expect(model.historyEpoch == ownEpoch)
    }

    @Test func aStampFromAnotherFileIdentityIsIgnored() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = try makeHost(writing: file.prefix(stampLines * lineBytes))
        let foreign = host.stamp(fileIdentity: identity + 1)

        let model = try makeModel(transcript: file, stamps: [foreign])
        #expect(model.currentSnapshot().historyEpoch != foreign.historyEpoch)

        let appendOnly = try makeModel(transcript: file.prefix(100 * lineBytes))
        #expect(appendOnly.append(file.suffix(from: 100 * lineBytes), transcriptEndByteOffset: UInt64(file.count), stamps: [foreign]))
        #expect(appendOnly.currentSnapshot().historyEpoch != foreign.historyEpoch)
    }

    @Test func aStampFromAnotherGridIsIgnored() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = try makeHost(writing: file.prefix(stampLines * lineBytes))
        let real = host.stamp()
        let otherRows = TerminalLiveFrameStamp(
            transcriptByteOffset: real.transcriptByteOffset, transcriptFileIdentity: identity, historyEpoch: 0x77, activeTopRow: real.activeTopRow,
            columns: columns, rows: rows + 1)
        let otherColumns = TerminalLiveFrameStamp(
            transcriptByteOffset: real.transcriptByteOffset, transcriptFileIdentity: identity, historyEpoch: 0x78, activeTopRow: real.activeTopRow,
            columns: columns + 1, rows: rows)

        let model = try makeModel(transcript: file, stamps: [otherRows, otherColumns])

        #expect(model.historyEpoch != 0x77 && model.historyEpoch != 0x78)
        model.align(with: [otherRows, otherColumns])
        #expect(model.historyEpoch != 0x77 && model.historyEpoch != 0x78)
    }

    // MARK: - Aligning without a write

    @Test func aReplayCaughtUpToTheFileEndAlignsFromAStampAtItsEnd() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = try makeHost(writing: file)
        let stampAtEnd = host.stamp()
        let model = try makeModel(transcript: file)
        #expect(model.historyEpoch != stampAtEnd.historyEpoch)

        model.align(with: [stampAtEnd])

        #expect(model.historyEpoch == stampAtEnd.historyEpoch)
        #expect(model.currentSnapshot().historyRowBase == host.snapshot.historyRowBase)
        #expect(HostTranscript.rowTexts(model.currentSnapshot()) == HostTranscript.rowTexts(host.snapshot))
    }

    @Test func alignWithIgnoresAStampAtAnotherOffset() throws {
        let file = HostTranscript.lines(1...fileLines)
        let host = try makeHost(writing: file.prefix(stampLines * lineBytes))
        let earlier = host.stamp()
        let model = try makeModel(transcript: file)
        let ownEpoch = model.historyEpoch

        model.align(with: [earlier])

        #expect(model.historyEpoch == ownEpoch)
    }

    // MARK: - Renumbering

    @Test func aClearInAppendedBytesDropsTheAlignmentUntilALaterStampRealigns() throws {
        let first = HostTranscript.lines(1...stampLines)
        let clearAndMore =
            HostTranscript.lines((stampLines + 1)...(stampLines + 20)) + Data("\u{1b}[3J".utf8)
            + HostTranscript.lines((stampLines + 21)...(stampLines + 30))
        let tail = HostTranscript.lines((stampLines + 31)...(stampLines + 50))
        let host = try makeHost(writing: first)
        let firstStamp = host.stamp()

        let model = try makeModel(transcript: first, stamps: [firstStamp])
        #expect(model.historyEpoch == firstStamp.historyEpoch)

        #expect(model.append(clearAndMore, transcriptEndByteOffset: UInt64(first.count + clearAndMore.count), stamps: []))
        #expect(model.historyEpoch != firstStamp.historyEpoch, "the clear renumbered the replay's rows, so the old alignment no longer holds")

        host.write(clearAndMore)
        host.write(tail)
        let realigningStamp = host.stamp()
        #expect(realigningStamp.historyEpoch != firstStamp.historyEpoch)
        #expect(
            model.append(tail, transcriptEndByteOffset: UInt64(first.count + clearAndMore.count + tail.count), stamps: [firstStamp, realigningStamp]))

        let hostFrame = host.snapshot
        let replayFrame = model.currentSnapshot()
        #expect(replayFrame.historyEpoch == realigningStamp.historyEpoch)
        #expect(replayFrame.historyRowBase == hostFrame.historyRowBase)
        #expect(HostTranscript.rowTexts(replayFrame) == HostTranscript.rowTexts(hostFrame))
        host.scroll(deltaRows: -2)
        let hostScrolled = host.snapshot
        let replayScrolled = try #require(model.scroll(deltaRows: -2).snapshot)
        #expect(replayScrolled.historyRowBase == hostScrolled.historyRowBase)
        #expect(HostTranscript.rowTexts(replayScrolled) == HostTranscript.rowTexts(hostScrolled))
    }
}
