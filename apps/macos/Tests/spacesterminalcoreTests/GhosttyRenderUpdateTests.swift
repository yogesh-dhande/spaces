import XCTest

@testable import spacesterminalcore

final class GhosttyRenderUpdateTests: XCTestCase {
    func testFullRenderUpdateBinaryRoundTrips() throws {
        let snapshot = makeSnapshot(lines: ["hello", "world"])
        let frame = GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: snapshot)
        let update = GhosttyRenderUpdate.full(frame)

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))

        XCTAssertEqual(decoded, update)
        XCTAssertEqual(decoded.fullFrame?.snapshot, snapshot)
    }

    func testCellRunDeltaRoundTripsAndApplies() throws {
        let previous = makeSnapshot(lines: ["hello"])
        let target = makeSnapshot(lines: ["hullo"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))
        let applied = try GhosttyRenderUpdateApplier.apply(decoded, to: baseline)

        XCTAssertEqual(decoded.kind, .delta)
        XCTAssertEqual(decoded.delta?.replaceCellRuns.count, 1)
        XCTAssertEqual(decoded.delta?.changedCellCount, 1)
        XCTAssertEqual(applied.snapshot, target)
        XCTAssertEqual(applied.sessionRevision, 2)
    }

    func testAppendedOutputDeltaUsesScrollRectAndBottomRowReplacement() throws {
        let previous = makeSnapshot(lines: ["one ", "two ", "tre "])
        let target = makeSnapshot(lines: ["two ", "tre ", "for "])
        let frame = GhosttyRenderFrame(sessionRevision: 12, ownerEpoch: 5, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 11, ownerEpoch: 5)
        let nativeScrollRects = [
            GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 3, columnStart: 0, columnCount: 4, deltaRows: -1, deltaColumns: 0)
        ]

        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, nativeScrollRects: nativeScrollRects)
        let delta = try XCTUnwrap(update.delta)
        let scroll = try XCTUnwrap(delta.scrollRects.first)
        let applied = try GhosttyRenderUpdateApplier.apply(update, to: baseline)

        XCTAssertEqual(update.kind, .delta)
        XCTAssertEqual(delta.scrollRects.count, 1)
        XCTAssertEqual(scroll.rowStart, 0)
        XCTAssertEqual(scroll.rowCount, 3)
        XCTAssertEqual(scroll.columnStart, 0)
        XCTAssertEqual(scroll.columnCount, 4)
        XCTAssertEqual(scroll.deltaRows, -1)
        XCTAssertEqual(scroll.deltaColumns, 0)
        XCTAssertEqual(delta.replaceCellRuns.map(\.row), [2])
        XCTAssertEqual(applied.snapshot, target)
    }

    func testScrollRectDeltaIsSmallerThanCellRunOnlyOneRowScrollFixture() throws {
        let columns = 80
        let rows = 24
        let previous = makeUniformRowSnapshot(columns: columns, rows: rows, firstScalar: 65)
        let target = makeUniformRowSnapshot(columns: columns, rows: rows, firstScalar: 66)
        let frame = GhosttyRenderFrame(sessionRevision: 12, ownerEpoch: 5, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 11, ownerEpoch: 5)
        let nativeScrollRects = [
            GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: rows, columnStart: 0, columnCount: columns, deltaRows: -1, deltaColumns: 0)
        ]

        let scrollRectUpdate = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, nativeScrollRects: nativeScrollRects)
        let scrollRectDelta = try XCTUnwrap(scrollRectUpdate.delta)
        let cellRunOnlyUpdate = GhosttyRenderUpdate.delta(
            GhosttyRenderDeltaFrame(
                baseRevision: baseline.sessionRevision, targetRevision: frame.sessionRevision, ownerEpoch: frame.ownerEpoch, columns: columns,
                rows: rows, cursorColumn: target.cursorColumn, cursorRow: target.cursorRow, cursorVisible: target.cursorVisible,
                defaultForegroundRGB: target.defaultForegroundRGB, defaultBackgroundRGB: target.defaultBackgroundRGB, scrollRects: [],
                replaceCellRuns: (0..<rows).map { row in
                    let start = row * columns
                    return GhosttyRenderCellRun(row: row, column: 0, cells: Array(target.cells[start..<(start + columns)]))
                }, changedCellCount: rows * columns))

        let scrollRectBytes = try GhosttyRenderUpdateBinaryCodec.encode(scrollRectUpdate).count
        let cellRunOnlyBytes = try GhosttyRenderUpdateBinaryCodec.encode(cellRunOnlyUpdate).count

        XCTAssertEqual(scrollRectDelta.scrollRects.count, 1)
        XCTAssertEqual(scrollRectDelta.replaceCellRuns.count, 1)
        XCTAssertEqual(scrollRectDelta.changedCellCount, columns)
        XCTAssertEqual(try GhosttyRenderUpdateApplier.apply(scrollRectUpdate, to: baseline).snapshot, target)
        XCTAssertEqual(scrollRectBytes, 1_215)
        XCTAssertEqual(cellRunOnlyBytes, 27_097)
        XCTAssertLessThan(scrollRectBytes, cellRunOnlyBytes)
    }

    /// The header peek exists so a caller can ask "is this a full frame?" without paying a grid decode,
    /// which means it has to answer exactly what a decode would — for every kind, and for anything that is
    /// not a render update at all. A blob it cannot classify reads as nil, which every caller treats as
    /// "not a full frame": the safe direction, since mistaking a delta for a full frame hands a client a
    /// screen it never received.
    func testEncodedKindPeekAgreesWithAFullDecode() throws {
        let previous = makeSnapshot(lines: ["hello"])
        let target = makeSnapshot(lines: ["hullo"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let updates: [GhosttyRenderUpdate] = [
            .full(frame), GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline),
            .resyncRequired(sessionRevision: 2, ownerEpoch: 1, columns: target.columns, rows: target.rows),
        ]
        XCTAssertEqual(updates.map(\.kind), [.full, .delta, .resyncRequired], "the fixture must cover every kind on the wire")

        for update in updates {
            let encoded = try GhosttyRenderUpdateBinaryCodec.encode(update)
            XCTAssertEqual(
                GhosttyRenderUpdateBinaryCodec.encodedKind(of: encoded), try GhosttyRenderUpdateBinaryCodec.decode(encoded).kind,
                "the peek must agree with the decode for a \(update.kind) update")
        }

        let encodedFull = try GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
        XCTAssertNil(GhosttyRenderUpdateBinaryCodec.encodedKind(of: Data()), "empty")
        XCTAssertNil(GhosttyRenderUpdateBinaryCodec.encodedKind(of: Data(encodedFull.prefix(5))), "too short to hold the header")
        XCTAssertNil(GhosttyRenderUpdateBinaryCodec.encodedKind(of: Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])), "wrong magic")
        var wrongVersion = Data(encodedFull)
        wrongVersion[4] = UInt8(GhosttyRenderUpdate.currentVersion + 1)
        XCTAssertNil(GhosttyRenderUpdateBinaryCodec.encodedKind(of: wrongVersion), "a version this build cannot decode")
        var unknownKind = Data(encodedFull)
        unknownKind[5] = 0x7F
        XCTAssertNil(GhosttyRenderUpdateBinaryCodec.encodedKind(of: unknownKind), "a kind byte this build does not know")
    }

    /// The peek reads the same header a decode does, including through a slice whose start index is not
    /// zero — the shape a render update takes when it arrives inside a larger buffer.
    func testEncodedKindPeekReadsASliceWithNonZeroStartIndex() throws {
        let frame = GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: makeSnapshot(lines: ["hello"]))
        let encoded = try GhosttyRenderUpdateBinaryCodec.encode(.full(frame))
        var padded = Data([0x11, 0x22, 0x33])
        padded.append(encoded)
        let slice = padded[3..<(3 + encoded.count)]

        XCTAssertEqual(GhosttyRenderUpdateBinaryCodec.encodedKind(of: slice), .full)
    }

    func testDecodeAcceptsDataSliceWithNonZeroStartIndex() throws {
        let snapshot = makeSnapshot(lines: ["hello", "world"])
        let frame = GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: snapshot)
        let update = GhosttyRenderUpdate.full(frame)
        let encoded = try GhosttyRenderUpdateBinaryCodec.encode(update)

        var padded = Data([0x11, 0x22, 0x33])
        padded.append(encoded)
        padded.append(contentsOf: [0x44, 0x55])
        let slice = padded[3..<(3 + encoded.count)]
        XCTAssertNotEqual(slice.startIndex, 0)

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(slice)
        XCTAssertEqual(decoded, update)
        XCTAssertEqual(decoded.fullFrame?.snapshot, snapshot)
    }

    func testTruncatedDataThrowsTruncatedAtEveryCutPoint() throws {
        // Both an all-ASCII frame and one whose cells carry clusters and a link, so the cut points that
        // land inside the sparse cell-text section are covered too.
        for lines in [["hello", "world"], ["a👋🏽b", "🇯🇵é🙂"]] {
            let snapshot = makeSnapshot(lines: lines)
            let frame = GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: snapshot)
            let encoded = try GhosttyRenderUpdateBinaryCodec.encode(GhosttyRenderUpdate.full(frame))

            // Every prefix shorter than the full frame must throw rather than crash. The magic check
            // requires the first magic.count bytes to match, so a zero-length prefix throws too. A cut
            // inside a payload's declared length can also surface as .invalidCellPayload, when the
            // truncated bytes happen to parse as an entry that does not describe its cell.
            for cut in 0..<encoded.count {
                let prefix = encoded.prefix(cut)
                XCTAssertThrowsError(try GhosttyRenderUpdateBinaryCodec.decode(prefix)) { error in
                    let codecError = error as? GhosttyRenderUpdateBinaryCodec.BinaryCodecError
                    XCTAssertTrue(
                        codecError == .truncated || codecError == .invalidMagic || codecError == .invalidCellPayload,
                        "cut \(cut) of \(lines) threw \(String(describing: codecError))")
                }
            }
        }
    }

    /// Grapheme clusters and OSC 8 links travel with the cell they belong to, so an emoji sequence, a
    /// combining mark, and a linked cell all survive a full frame intact rather than collapsing to a
    /// base scalar.
    func testClusterAndLinkCellsRoundTripThroughAFullFrame() throws {
        // A link on a plain ASCII cell (index 5) and a link on a cluster cell (index 4): both payload
        // kinds on one frame.
        let snapshot = makeSnapshot(lines: ["❤️👋🏽", "👨‍👩‍👧‍👦🇯🇵", "e\u{0301}x"], linkURLs: [4: "https://example.com/b", 5: "https://example.com/a"])
        let update = GhosttyRenderUpdate.full(GhosttyRenderFrame(sessionRevision: 7, ownerEpoch: 3, snapshot: snapshot))

        let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))

        XCTAssertEqual(decoded, update)
        let decodedSnapshot = try XCTUnwrap(decoded.fullFrame?.snapshot)
        XCTAssertEqual(decodedSnapshot.clusters[0], "❤️")
        XCTAssertEqual(decodedSnapshot.clusters[1], "👋🏽")
        XCTAssertEqual(decodedSnapshot.clusters[2], "👨‍👩‍👧‍👦")
        XCTAssertEqual(decodedSnapshot.clusters[3], "🇯🇵")
        XCTAssertEqual(decodedSnapshot.clusters[4], "e\u{0301}")
        XCTAssertEqual(decodedSnapshot.linkURLs[4], "https://example.com/b")
        XCTAssertNil(decodedSnapshot.clusters[5])
        XCTAssertEqual(decodedSnapshot.linkURLs[5], "https://example.com/a")
        XCTAssertEqual(GhosttyTerminalSnapshotGrid.fullPlainText(for: decodedSnapshot), "❤️👋🏽\n👨‍👩‍👧‍👦🇯🇵\ne\u{0301}x")
    }

    /// Cluster support must cost an all-ASCII frame nothing on the wire: the flag bits that mark a
    /// payload live in the cell's existing flags word, and a block with no flagged cell writes no
    /// sparse section at all.
    func testAsciiFrameCostsOnlyTheFixedPerCellBytes() throws {
        let snapshot = makeSnapshot(lines: ["hello", "world"])
        let update = GhosttyRenderUpdate.full(GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: snapshot))

        // 46-byte update header (magic 4, version 1, kind 1, reserved 2, three revisions 24, owner
        // epoch 8, columns 2, rows 2, empty fallback reason 2), 19-byte snapshot header, 14 bytes a cell.
        XCTAssertEqual(try GhosttyRenderUpdateBinaryCodec.encode(update).count, 46 + 19 + snapshot.cells.count * 14)

        // One cluster cell adds exactly its sparse entry: 4-byte offset, 2-byte length, utf8 bytes.
        let clustered = makeSnapshot(lines: ["👋🏽ello", "world"])
        let clusteredUpdate = GhosttyRenderUpdate.full(GhosttyRenderFrame(sessionRevision: 4, ownerEpoch: 9, snapshot: clustered))
        XCTAssertEqual(
            try GhosttyRenderUpdateBinaryCodec.encode(clusteredUpdate).count, 46 + 19 + snapshot.cells.count * 14 + 6 + Array("👋🏽".utf8).count)
    }

    /// No representable snapshot may encode to a frame its own decoder rejects, so the tables normalize
    /// on the way in: empty and over-cap text degrade the cell to its base codepoint exactly as the
    /// producers do, and an entry naming a cell the block does not contain — which the wire has no way
    /// to address — is dropped. Runs normalize the same way, against their own cell count.
    func testCellTextTablesNormalizeEmptyOverCapAndOutOfRangeEntries() {
        let overCap = "e" + String(repeating: "\u{0301}", count: GhosttyTerminalSnapshot.maximumClusterCodepointCount)
        XCTAssertNil(makeSnapshot(lines: ["ab"], clusters: [0: overCap]).clusters[0])
        XCTAssertNil(makeSnapshot(lines: ["ab"], clusters: [0: ""]).clusters[0])
        XCTAssertNil(makeSnapshot(lines: ["ab"], linkURLs: [0: ""]).linkURLs[0])
        XCTAssertNil(makeSnapshot(lines: ["ab"], clusters: [7: "e\u{0301}"]).clusters[7])
        XCTAssertEqual(makeSnapshot(lines: ["ab"], clusters: [0: "e\u{0301}"]).clusters[0], "e\u{0301}")

        // A link past the byte cap is dropped whole rather than carried into a frame the encoder
        // would then refuse — the daemon export paths swallow encode errors, so an unencodable link
        // would silence render updates for as long as it stayed visible.
        let overCapLink = "https://example.com/" + String(repeating: "a", count: GhosttyTerminalSnapshot.maximumLinkURLUTF8ByteCount)
        XCTAssertNil(makeSnapshot(lines: ["ab"], linkURLs: [0: overCapLink]).linkURLs[0])
        let atCapLink = "https://" + String(repeating: "a", count: GhosttyTerminalSnapshot.maximumLinkURLUTF8ByteCount - 8)
        XCTAssertEqual(makeSnapshot(lines: ["ab"], linkURLs: [0: atCapLink]).linkURLs[0], atCapLink)

        let run = GhosttyRenderCellRun(row: 0, column: 0, cells: [makeCell("a")], clusters: [0: "e\u{0301}", 1: "e\u{0301}"], linkURLs: [0: ""])
        XCTAssertEqual(run.clusters, [0: "e\u{0301}"])
        XCTAssertEqual(run.linkURLs, [:])
    }

    /// A cluster longer than the cap is malformed rather than something the decoder stretches to hold:
    /// producers (and the snapshot's own normalization) degrade such a cell to its base codepoint, so a
    /// frame carrying one did not come from a producer this build trusts. The fixture is byte-crafted
    /// because no representable snapshot can encode it.
    func testClusterLongerThanTheCapIsRejected() throws {
        let cells = [GhosttyTerminalSnapshot.Cell(codepoint: 101, foregroundRGB: 0, backgroundRGB: 0, flags: 0)]
        let snapshot = GhosttyTerminalSnapshot(
            columns: 1, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0, defaultBackgroundRGB: 0, cells: cells,
            clusters: [0: "e\u{0301}"])
        let encoded = try GhosttyRenderUpdateBinaryCodec.encode(
            GhosttyRenderUpdate.full(GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)))

        // The frame's only sparse entry is last: [UInt32 offset][UInt16 length][utf8 bytes]. Swap the
        // in-cap cluster ("e" + one mark, 3 bytes) for one codepoint past the cap, within the byte cap
        // so the codepoint check is the one that fires.
        let inCapBytes = Array("e\u{0301}".utf8)
        let oversizedBytes = Array(("e" + String(repeating: "\u{0301}", count: GhosttyTerminalSnapshot.maximumClusterCodepointCount)).utf8)
        var crafted = encoded.dropLast(inCapBytes.count + 2)
        withUnsafeBytes(of: UInt16(oversizedBytes.count).littleEndian) { crafted.append(contentsOf: $0) }
        crafted.append(contentsOf: oversizedBytes)

        XCTAssertThrowsError(try GhosttyRenderUpdateBinaryCodec.decode(crafted)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateBinaryCodec.BinaryCodecError, .invalidCellPayload)
        }
    }

    /// A cell-text entry whose declared length runs past the end of the frame must be rejected, not
    /// read out of bounds; a zero-length one is malformed because a flagged cell always has text.
    func testCellTextLengthIsValidatedAgainstTheRemainingBuffer() throws {
        let snapshot = makeSnapshot(lines: ["a👋🏽"])
        let encoded = try GhosttyRenderUpdateBinaryCodec.encode(
            GhosttyRenderUpdate.full(GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)))
        // The frame's only sparse entry is last: [UInt32 offset][UInt16 length][utf8 bytes].
        let lengthIndex = encoded.count - Array("👋🏽".utf8).count - 2

        // A length within the cluster cap but past the end of the frame: the read is refused, not
        // clamped or run off the buffer.
        var overrun = encoded
        overrun[lengthIndex] = 60
        overrun[lengthIndex + 1] = 0x00
        XCTAssertThrowsError(try GhosttyRenderUpdateBinaryCodec.decode(overrun)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateBinaryCodec.BinaryCodecError, .truncated)
        }

        var empty = encoded
        empty[lengthIndex] = 0x00
        empty[lengthIndex + 1] = 0x00
        XCTAssertThrowsError(try GhosttyRenderUpdateBinaryCodec.decode(empty)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateBinaryCodec.BinaryCodecError, .invalidCellPayload)
        }
    }

    /// The version byte is the only guard for payloads that outlive a build (persisted final frames,
    /// demo recordings). A frame from another layout is rejected outright rather than misread.
    func testDecodeRejectsAnotherVersionsFrame() throws {
        let snapshot = makeSnapshot(lines: ["hello"])
        var encoded = try GhosttyRenderUpdateBinaryCodec.encode(
            GhosttyRenderUpdate.full(GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)))
        encoded[4] = UInt8(GhosttyRenderUpdate.currentVersion - 1)

        XCTAssertThrowsError(try GhosttyRenderUpdateBinaryCodec.decode(encoded)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateBinaryCodec.BinaryCodecError, .unsupportedVersion)
        }
    }

    /// The applier repeats the version guard for updates that reach it without passing through the
    /// binary decoder (a JSON-decoded persisted frame), so a stale baseline is never grown from one.
    func testApplyRejectsAnotherVersionsUpdate() throws {
        let snapshot = makeSnapshot(lines: ["hello"])
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)
        let update = GhosttyRenderUpdate(
            version: GhosttyRenderUpdate.currentVersion - 1, kind: .full, sessionRevision: 1, baseRevision: nil, targetRevision: 1, ownerEpoch: 1,
            columns: snapshot.columns, rows: snapshot.rows, fullFrame: frame, delta: nil)

        XCTAssertThrowsError(try GhosttyRenderUpdateApplier.apply(update, to: nil)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateApplyError, .versionMismatch)
        }
    }

    /// A scroll rect moves whole cells, so a cluster rides along with the row it belongs to instead of
    /// being rebuilt from a base codepoint at the destination.
    func testScrollRectMovesAClusterCell() throws {
        let previous = makeSnapshot(lines: ["👋🏽ab", "cdef", "ghij"])
        let target = makeSnapshot(lines: ["cdef", "ghij", "klmn"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let scrollRects = [GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 3, columnStart: 0, columnCount: 4, deltaRows: -1, deltaColumns: 0)]

        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline, nativeScrollRects: scrollRects)
        let applied = try GhosttyRenderUpdateApplier.apply(
            try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update)), to: baseline)

        XCTAssertEqual(applied.snapshot, target)

        // The same scroll with the cluster row surviving the move: it lands one row up carried by the
        // scroll rect alone, so no replacement run repaints it.
        let stayingPrevious = makeSnapshot(lines: ["cdef", "efgh", "👋🏽ab"])
        let stayingTarget = makeSnapshot(lines: ["cdef", "👋🏽ab", "klmn"])
        let stayingBaseline = GhosttyRenderUpdateBaseline(snapshot: stayingPrevious, sessionRevision: 1, ownerEpoch: 1)
        let stayingUpdate = GhosttyRenderUpdateFactory.makeUpdate(
            target: GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: stayingTarget), baseline: stayingBaseline,
            nativeScrollRects: [
                GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 3, columnStart: 0, columnCount: 4, deltaRows: -1, deltaColumns: 0)
            ])
        let stayingDecoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(stayingUpdate))
        let stayingApplied = try GhosttyRenderUpdateApplier.apply(stayingDecoded, to: stayingBaseline)
        XCTAssertEqual(stayingDecoded.delta?.replaceCellRuns.map(\.row), [0, 2])
        XCTAssertEqual(stayingApplied.snapshot.clusters[4], "👋🏽")
        XCTAssertEqual(stayingApplied.snapshot, stayingTarget)
    }

    /// Cells move by index, so the entries that name them have to be rekeyed to the exact destination
    /// index and the vacated cells left with none — otherwise a cluster smears onto whatever text lands
    /// where it used to be.
    func testScrollRectRekeysCellTextToTheDestinationIndex() throws {
        let baseline = makeSnapshot(lines: ["👋🏽ab", "cde", "fgh"], linkURLs: [1: "https://example.com"])
        let delta = GhosttyRenderDeltaFrame(
            baseRevision: 1, targetRevision: 2, ownerEpoch: 1, columns: 3, rows: 3, cursorColumn: 0, cursorRow: 0, cursorVisible: false,
            defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            scrollRects: [GhosttyRenderScrollRectOperation(rowStart: 0, rowCount: 3, columnStart: 0, columnCount: 3, deltaRows: 1, deltaColumns: 0)],
            changedCellCount: 0)

        let applied = try GhosttyRenderUpdateApplier.apply(delta, to: baseline)

        // Row 0 moved down one row, so its cluster is at index 3 and its linked neighbour at index 4,
        // with nothing left behind at the indices they came from.
        XCTAssertEqual(applied.clusters, [3: "👋🏽"])
        XCTAssertEqual(applied.linkURLs, [4: "https://example.com"])
        XCTAssertEqual(GhosttyTerminalSnapshotGrid.fullPlainText(for: applied), "   \n👋🏽ab\ncde")
    }

    /// A run's entries are keyed within the run and land at its destination; applying it rewrites the
    /// text of every cell it covers — so an ASCII cell replacing a cluster cell clears it — and leaves
    /// the cells past its own length alone.
    func testCellRunRewritesCellTextOnlyWithinItsOwnSpan() throws {
        let baseline = makeSnapshot(lines: ["👋🏽b🇯🇵d"], linkURLs: [0: "https://example.com"])
        let replacement = makeSnapshot(lines: ["xe\u{0301}"])
        let delta = GhosttyRenderDeltaFrame(
            baseRevision: 1, targetRevision: 2, ownerEpoch: 1, columns: 4, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false,
            defaultForegroundRGB: 0xEEEEEE, defaultBackgroundRGB: 0x101010,
            replaceCellRuns: [GhosttyRenderCellRun(row: 0, column: 0, cells: replacement.cells, clusters: replacement.clusters)], changedCellCount: 2)

        let applied = try GhosttyRenderUpdateApplier.apply(delta, to: baseline)

        XCTAssertEqual(applied.clusters, [1: "e\u{0301}", 2: "🇯🇵"])
        XCTAssertEqual(applied.linkURLs, [:])
        XCTAssertEqual(GhosttyTerminalSnapshotGrid.fullPlainText(for: applied), "xe\u{0301}🇯🇵d")
    }

    /// A crop renumbers every cell it keeps, so the entries are rebased into the cropped grid's
    /// coordinates and the ones outside the window are dropped.
    func testViewportCropRebasesCellText() {
        let snapshot = makeSnapshot(lines: ["ab👋🏽d", "efgh", "ij🇯🇵l"], linkURLs: [7: "https://example.com"])

        let cropped = GhosttyTerminalSnapshotViewport.crop(
            snapshot, window: GhosttyTerminalSnapshotViewport.Window(columnOffset: 2, rowOffset: 0, columns: 2, rows: 2))

        // Source index 2 (row 0, column 2) lands at 0 and the link at source index 7 (row 1, column 3)
        // at 3; the second cluster's row is outside the window entirely.
        XCTAssertEqual(cropped.clusters, [0: "👋🏽"])
        XCTAssertEqual(cropped.linkURLs, [3: "https://example.com"])
        XCTAssertEqual(GhosttyTerminalSnapshotGrid.fullPlainText(for: cropped), "👋🏽d\ngh")
    }

    /// A cluster is part of a cell's identity, so replacing it with ASCII drops it, writing one over a
    /// plain cell adds it, and swapping one cluster for another that shares its base codepoint still
    /// changes the cell — the skin-tone case, where only the modifier differs.
    func testClusterChangesDriveCellRuns() throws {
        func applyDelta(from previous: GhosttyTerminalSnapshot, to target: GhosttyTerminalSnapshot) throws -> GhosttyRenderUpdate {
            let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
            let update = GhosttyRenderUpdateFactory.makeUpdate(
                target: GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target), baseline: baseline)
            let decoded = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))
            XCTAssertEqual(try GhosttyRenderUpdateApplier.apply(decoded, to: baseline).snapshot, target)
            return decoded
        }

        let clusterToAscii = try applyDelta(from: makeSnapshot(lines: ["👋🏽ab"]), to: makeSnapshot(lines: ["xab"]))
        XCTAssertEqual(clusterToAscii.delta?.changedCellCount, 1)
        XCTAssertEqual(clusterToAscii.delta?.replaceCellRuns.first?.clusters, [:])

        let asciiToCluster = try applyDelta(from: makeSnapshot(lines: ["xab"]), to: makeSnapshot(lines: ["👋🏽ab"]))
        XCTAssertEqual(asciiToCluster.delta?.changedCellCount, 1)
        XCTAssertEqual(asciiToCluster.delta?.replaceCellRuns.first?.clusters, [0: "👋🏽"])

        // "👋" and "👋🏽" share a base codepoint; only the cluster tells them apart.
        let skinToneOnly = try applyDelta(from: makeSnapshot(lines: ["👋ab"]), to: makeSnapshot(lines: ["👋🏽ab"]))
        XCTAssertEqual(skinToneOnly.delta?.changedCellCount, 1)
        XCTAssertEqual(skinToneOnly.delta?.replaceCellRuns.first?.clusters, [0: "👋🏽"])

        // A link change alone is a cell change too, for the same reason.
        let linkOnly = try applyDelta(from: makeSnapshot(lines: ["xab"]), to: makeSnapshot(lines: ["xab"], linkURLs: [0: "https://example.com"]))
        XCTAssertEqual(linkOnly.delta?.changedCellCount, 1)
        XCTAssertEqual(linkOnly.delta?.replaceCellRuns.first?.linkURLs, [0: "https://example.com"])
    }

    func testTruncatedSliceWithNonZeroStartIndexThrowsTruncated() throws {
        let previous = makeSnapshot(lines: ["one ", "two ", "tre "])
        let target = makeSnapshot(lines: ["two ", "tre ", "for "])
        let frame = GhosttyRenderFrame(sessionRevision: 12, ownerEpoch: 5, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 11, ownerEpoch: 5)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)
        let encoded = try GhosttyRenderUpdateBinaryCodec.encode(update)

        var padded = Data([0x11, 0x22, 0x33])
        padded.append(encoded)
        // Cut inside the body (well past the magic) so the reader hits an out-of-bounds read on a slice.
        let slice = padded[3..<(3 + encoded.count - 4)]
        XCTAssertThrowsError(try GhosttyRenderUpdateBinaryCodec.decode(slice)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateBinaryCodec.BinaryCodecError, .truncated)
        }
    }

    func testDeltaRejectsBaseRevisionMismatch() throws {
        let previous = makeSnapshot(lines: ["abc"])
        let target = makeSnapshot(lines: ["abd"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)
        let staleBaseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 0, ownerEpoch: 1)

        XCTAssertThrowsError(try GhosttyRenderUpdateApplier.apply(update, to: staleBaseline)) { error in
            XCTAssertEqual(error as? GhosttyRenderUpdateApplyError, .baseRevisionMismatch(expected: 1, actual: 0))
        }
    }

    func testFullUpdateIsUsedWhenBaselineIsUnsafe() {
        let previous = makeSnapshot(lines: ["abc"])
        let target = makeSnapshot(lines: ["abc", "def"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)

        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)

        XCTAssertEqual(update.kind, .full)
        XCTAssertEqual(update.fallbackReason, "baseline_mismatch")
        XCTAssertEqual(update.fullFrame?.snapshot, target)
    }

    /// Mouse-reporting state decides whether a client's pane click belongs to the application or to
    /// local selection, so it has to survive both frame shapes. The delta is the one that matters in
    /// practice: an application enabling or disabling mouse tracking mid-session is an ordinary screen
    /// change that never forces a full frame.
    func testMouseReportingStateSurvivesFullAndDeltaFrames() throws {
        let previous = makeSnapshot(lines: ["hello"])
        let target = makeSnapshot(lines: ["hullo"], mouseReportingActive: true, mouseShiftCapture: GhosttyTerminalSnapshot.mouseShiftCaptureEnabled)
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)

        let full = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        XCTAssertEqual(full.fullFrame?.snapshot.mouseReportingActive, true)
        XCTAssertEqual(full.fullFrame?.snapshot.mouseShiftCapture, GhosttyTerminalSnapshot.mouseShiftCaptureEnabled)

        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)
        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)
        let delta = try GhosttyRenderUpdateBinaryCodec.decode(try GhosttyRenderUpdateBinaryCodec.encode(update))
        XCTAssertEqual(delta.kind, .delta)
        XCTAssertEqual(delta.delta?.mouseReportingActive, true)
        XCTAssertEqual(delta.delta?.mouseShiftCapture, GhosttyTerminalSnapshot.mouseShiftCaptureEnabled)

        let applied = try GhosttyRenderUpdateApplier.apply(delta, to: baseline)
        XCTAssertEqual(applied.snapshot, target)
        XCTAssertTrue(applied.snapshot.mouseReportingActive)
    }

    /// The application turning mouse tracking back off has to reach the client the same way, or a pane
    /// would keep forwarding clicks to a program that stopped listening instead of selecting text.
    func testMouseReportingStateClearsThroughADelta() throws {
        let previous = makeSnapshot(lines: ["hello"], mouseReportingActive: true)
        let target = makeSnapshot(lines: ["hullo"])
        let frame = GhosttyRenderFrame(sessionRevision: 2, ownerEpoch: 1, snapshot: target)
        let baseline = GhosttyRenderUpdateBaseline(snapshot: previous, sessionRevision: 1, ownerEpoch: 1)

        let update = GhosttyRenderUpdateFactory.makeUpdate(target: frame, baseline: baseline)
        let applied = try GhosttyRenderUpdateApplier.apply(update, to: baseline)

        XCTAssertFalse(applied.snapshot.mouseReportingActive)
    }

    /// The cell a character occupies. Only its base codepoint lives in the cell; a multi-scalar
    /// character's full text is a snapshot entry, which `makeSnapshot` records.
    private func makeCell(_ character: Character) -> GhosttyTerminalSnapshot.Cell {
        GhosttyTerminalSnapshot.Cell(
            codepoint: character.unicodeScalars.first?.value ?? 0x20, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0)
    }

    /// One cell per grapheme cluster, so a fixture line may mix ASCII with multi-scalar characters and
    /// still describe one cell per column. A character that is a single scalar contributes no cluster
    /// entry — the fast path the wire format is built around. `clusters` and `linkURLs` add entries on
    /// top, keyed by cell index, for fixtures that need text no character can express.
    private func makeSnapshot(
        lines: [String], clusters: [Int: String] = [:], linkURLs: [Int: String] = [:], mouseReportingActive: Bool = false,
        mouseShiftCapture: UInt8 = GhosttyTerminalSnapshot.mouseShiftCaptureUnset
    ) -> GhosttyTerminalSnapshot {
        let columns = lines.map(\.count).max() ?? 1
        let rows = max(lines.count, 1)
        let paddedLines =
            lines.isEmpty ? [String(repeating: " ", count: columns)] : lines.map { $0 + String(repeating: " ", count: columns - $0.count) }
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        var cellClusters = clusters
        for line in paddedLines {
            for character in line {
                if character.unicodeScalars.count > 1 { cellClusters[cells.count] = String(character) }
                cells.append(makeCell(character))
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: rows - 1, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE,
            defaultBackgroundRGB: 0x101010, cells: cells, clusters: cellClusters, linkURLs: linkURLs, mouseReportingActive: mouseReportingActive,
            mouseShiftCapture: mouseShiftCapture)
    }

    private func makeUniformRowSnapshot(columns: Int, rows: Int, firstScalar: UInt32) -> GhosttyTerminalSnapshot {
        let cells = (0..<rows).flatMap { row in
            Array(
                repeating: GhosttyTerminalSnapshot.Cell(
                    codepoint: firstScalar + UInt32(row), foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: 0), count: columns)
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: 0, cursorRow: rows - 1, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE,
            defaultBackgroundRGB: 0x101010, cells: cells)
    }
}
