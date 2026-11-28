import XCTest

@testable import spacesterminalcore

final class TerminalHardWrappedLinkTests: XCTestCase {
    private let path = "/Users/dev/projects/spaces/apps/macos/Sources/File.swift"

    /// Claude Code's layout: the first row is filled to the last column, the rest follows two columns in.
    private func wrappedPath(columns: Int = 40) -> [String] {
        let text = Array(path)
        return [String(text.prefix(columns)), "  " + String(text.dropFirst(columns))]
    }

    func testClickOnFirstRowJoinsTheContinuation() {
        let rows = wrappedPath()
        let snapshot = Self.snapshot(columns: 40, rows: rows)
        let first = String(rows[0])
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(first, row: 0, column: 5, in: snapshot), path)
    }

    func testClickOnContinuationRowJoinsTheFirstRow() {
        let rows = wrappedPath()
        let snapshot = Self.snapshot(columns: 40, rows: rows)
        let continuation = String(rows[1].dropFirst(2))
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(continuation, row: 1, column: 4, in: snapshot), path)
    }

    func testThreeRowChainJoinsFromAnyRow() {
        let text = Array(path + "/Extra/More/Nested.swift")
        let columns = 30
        let rows = [
            String(text.prefix(columns)),
            "  " + String(text.dropFirst(columns).prefix(columns - 2)),
            "  " + String(text.dropFirst(columns + columns - 2)),
        ]
        let snapshot = Self.snapshot(columns: columns, rows: rows)
        let expected = String(text)
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(rows[0], row: 0, column: 3, in: snapshot), expected)
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(String(rows[1].dropFirst(2)), row: 1, column: 6, in: snapshot), expected)
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(String(rows[2].dropFirst(2)), row: 2, column: 4, in: snapshot), expected)
    }

    func testPathThatStopsShortOfTheLastColumnIsNotJoined() {
        let snapshot = Self.snapshot(columns: 40, rows: ["see /tmp/short.txt", "  continued words"])
        XCTAssertNil(TerminalHardWrappedLink.joinedFilePath("/tmp/short.txt", row: 0, column: 8, in: snapshot))
    }

    func testURLReachingTheLastColumnIsNotJoined() {
        let url = "https://example.com/a/very/long/path/that/fills/the/row"
        let snapshot = Self.snapshot(columns: 40, rows: [String(url.prefix(40)), "  " + String(url.dropFirst(40))])
        XCTAssertNil(TerminalHardWrappedLink.joinedFilePath(String(url.prefix(40)), row: 0, column: 5, in: snapshot))
    }

    func testSoftWrappedRowsAreLeftToTheTerminal() {
        let rows = wrappedPath()
        let snapshot = Self.snapshot(columns: 40, rows: rows, flagsByRow: [0: GhosttyTerminalSnapshotGrid.rowWrapFlag, 1: GhosttyTerminalSnapshotGrid.rowWrapContinuationFlag])
        XCTAssertNil(TerminalHardWrappedLink.joinedFilePath(rows[0], row: 0, column: 5, in: snapshot))
    }

    func testSentencePunctuationAfterTheContinuationIsStripped() {
        let rows = wrappedPath()
        let snapshot = Self.snapshot(columns: 40, rows: [rows[0], rows[1] + "."])
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(rows[0], row: 0, column: 5, in: snapshot), path)
    }

    /// A wide glyph before the path ("界") and one inside it ("資料") each take two columns, so the path
    /// fills columns 3...39 only when the spacer cells are folded into their glyphs.
    func testWideCharactersBeforeAndInsideThePathKeepColumnsAligned() {
        let link = "/資料/" + String(repeating: "a", count: 31)
        // Scalars 0, 3 and 4 of the row are the wide ones.
        let row0 = "界 " + link
        XCTAssertEqual(row0.unicodeScalars.count + 3, 40)
        let snapshot = Self.snapshot(columns: 40, rows: [row0, "  tail.swift"], wideRowCells: [0: [0, 3, 4]])
        let joined = link + "tail.swift"
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(link, row: 0, column: 20, in: snapshot), joined)
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(link, row: 0, column: 5, in: snapshot), joined, "the spacer half of 資")
    }

    /// The same path twice in a row, only the second reaching the edge: a click on each copy resolves
    /// against that copy, so the first is not joined.
    func testTheSamePathTwiceInARowIsJoinedOnlyWhereItReachesTheEdge() {
        let copy = "/a/bb/c.txt"
        let row0 = copy + String(repeating: " ", count: 40 - 2 * copy.count) + copy
        XCTAssertEqual(row0.count, 40)
        let snapshot = Self.snapshot(columns: 40, rows: [row0, "  xyz"])
        XCTAssertNil(TerminalHardWrappedLink.joinedFilePath(copy, row: 0, column: 2, in: snapshot))
        XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(copy, row: 0, column: 35, in: snapshot), copy + "xyz")
    }

    /// Prose ending at the edge above a path would join into `at:src/foo.swift`, which parses as a scheme.
    func testProseAboveAContinuationIsNotJoinedIntoASchemeLikeString() {
        let row0 = String(repeating: "x ", count: 18) + " at:"
        XCTAssertEqual(row0.count, 40)
        let snapshot = Self.snapshot(columns: 40, rows: [row0, "  src/foo.swift:12"])
        let click = (column: 4, row: 1, snapshot: snapshot)
        XCTAssertNil(TerminalHardWrappedLink.joinedFilePath("src/foo.swift:12", row: 1, column: 4, in: snapshot))
        XCTAssertEqual(
            TerminalHardWrappedLink.openCandidates(for: "src/foo.swift:12", isHyperlink: false, click: click),
            ["src/foo.swift:12", "src/foo.swift"])
    }

    /// A wrapped plain-text URL whose continuation looks like a bare path must not get the URL prepended.
    func testWrappedURLContinuationIsNotJoinedIntoAURL() {
        let row0 = "https://example.com/some/long/path/witha"
        XCTAssertEqual(row0.count, 40)
        let snapshot = Self.snapshot(columns: 40, rows: [row0, "  aaaa/ccc.txt:7"])
        let click = (column: 4, row: 1, snapshot: snapshot)
        XCTAssertNil(TerminalHardWrappedLink.joinedFilePath("aaaa/ccc.txt:7", row: 1, column: 4, in: snapshot))
        XCTAssertEqual(
            TerminalHardWrappedLink.openCandidates(for: "aaaa/ccc.txt:7", isHyperlink: false, click: click), ["aaaa/ccc.txt:7", "aaaa/ccc.txt"])
    }

    func testOpenCandidatesKeepAURLPortAsASingleCandidate() {
        let snapshot = Self.snapshot(columns: 40, rows: ["http://host:8080"])
        XCTAssertEqual(
            TerminalHardWrappedLink.openCandidates(for: "http://host:8080", isHyperlink: false, click: (column: 3, row: 0, snapshot: snapshot)),
            ["http://host:8080"])
    }

    func testPathsWithoutASchemeLookingPrefixStillJoin() {
        for first in ["/abs/path/with/a/long/dir/name/aaaaaaaaaaaaaa", "./rel/path/with/a/long/dir/name/aaaaaaaaaaaaaaa", "~/x/path/with/a/long/dir/name/aaaaaaaaaaaaaaaaa"] {
            let padded = String(first.prefix(40)) + String(repeating: "a", count: max(0, 40 - first.count))
            let snapshot = Self.snapshot(columns: 40, rows: [padded, "  tail.swift"])
            XCTAssertEqual(TerminalHardWrappedLink.joinedFilePath(padded, row: 0, column: 3, in: snapshot), padded + "tail.swift")
        }
    }

    func testOpenCandidatesStripLineAndColumnSuffixesAfterTheLiteralText() {
        let snapshot = Self.snapshot(columns: 40, rows: ["see src/foo.swift:431"])
        func candidates(_ link: String) -> [String] {
            TerminalHardWrappedLink.openCandidates(for: link, isHyperlink: false, click: (column: 6, row: 0, snapshot: snapshot))
        }
        XCTAssertEqual(candidates("src/foo.swift:431"), ["src/foo.swift:431", "src/foo.swift"])
        XCTAssertEqual(candidates("src/foo.swift:431:7"), ["src/foo.swift:431:7", "src/foo.swift"])
        XCTAssertEqual(candidates("src/foo.swift"), ["src/foo.swift"])
        XCTAssertEqual(candidates("src/foo.swift:abc"), ["src/foo.swift:abc"])
    }

    func testOpenCandidatesLeaveAHyperlinkAlone() {
        XCTAssertEqual(
            TerminalHardWrappedLink.openCandidates(for: "/a/b.swift:12", isHyperlink: true, click: nil), ["/a/b.swift:12"])
    }

    func testOpenCandidatesCombineTheJoinWithTheLineSuffix() {
        let text = Array("/Users/dev/projects/spaces/apps/macos/Sources/File.swift:431")
        let rows = [String(text.prefix(40)), "  " + String(text.dropFirst(40))]
        let snapshot = Self.snapshot(columns: 40, rows: rows)
        let matched = String(text.prefix(40))
        XCTAssertEqual(
            TerminalHardWrappedLink.openCandidates(for: matched, isHyperlink: false, click: (column: 3, row: 0, snapshot: snapshot)),
            [
                "/Users/dev/projects/spaces/apps/macos/Sources/File.swift:431", "/Users/dev/projects/spaces/apps/macos/Sources/File.swift",
                matched,
            ])
    }

    /// `wideRowCells` lists the columns per row whose glyph is double width: the next cell becomes a spacer.
    private static func snapshot(
        columns: Int, rows: [String], flagsByRow: [Int: UInt16] = [:], wideRowCells: [Int: [Int]] = [:]
    ) -> GhosttyTerminalSnapshot {
        let rowCount = rows.count + 1
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        for row in 0..<rowCount {
            var scalars: [UInt32] = row < rows.count ? rows[row].unicodeScalars.map(\.value) : []
            let wideColumns = (wideRowCells[row] ?? []).sorted()
            for wide in wideColumns.reversed() { scalars.insert(0x20, at: wide + 1) }
            // Each earlier spacer pushes a later glyph, and so its spacer, one column right.
            let spacerColumns = Set(wideColumns.enumerated().map { $0.element + 1 + $0.offset })
            for column in 0..<columns {
                let scalar = column < scalars.count ? scalars[column] : 0x20
                var flags = flagsByRow[row] ?? 0
                if spacerColumns.contains(column) { flags |= GhosttyTerminalSnapshotGrid.spacerFlag }
                cells.append(.init(codepoint: scalar, foregroundRGB: 0xEEEEEE, backgroundRGB: 0x101010, flags: flags))
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: rowCount, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xEEEEEE,
            defaultBackgroundRGB: 0x101010, cells: cells)
    }
}
