import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// The snapshot export side of grapheme fidelity, driven by a real terminal: a program writes emoji
/// sequences to a PTY, Ghostty parses and clusters them, and the snapshot the session exports must
/// carry each cluster in one cell rather than collapsing it to its base scalar.
///
/// Kept apart from the mirror suites because only one embedded ghostty app may be live per process
/// (`GhosttyProcessAppRuntime`): a session core starts the daemon-owned app, a mirror view starts the
/// app-owned one, and the parallel test runner gives each test class its own process.
final class GhosttyEmbeddedSessionGraphemeExportTests: XCTestCase {
    /// Clusters a terminal keeps in a single cell under grapheme clustering: a variation selector, a
    /// skin-tone modifier, a four-member ZWJ family, a regional-indicator flag, and a combining mark.
    private static let sequences = ["\u{2764}\u{FE0F}", "👋🏽", "👨‍👩‍👧‍👦", "🇯🇵", "e\u{0301}"]
    private static let family = "👨‍👩‍👧‍👦"
    private static let linkURL = "https://example.com/x"

    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    /// Binds an isolated profile so session persistence never resolves a live profile root (SpacesProfile refuses that in test processes).
    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        originalRuntimeDirectory = nil
        try super.tearDownWithError()
    }

    func testEmbeddedSessionExportsGraphemeClusters() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        // Grapheme clustering (mode 2027) is what makes a terminal keep a multi-codepoint sequence in
        // one cell; the sequences are printed one per line so each lands at a known row.
        let printed = Self.sequences.map { "'\($0)|'" }.joined(separator: " ")
        let command = "stty -echo; printf '\\033[?2027h'; printf '%s\\n' \(printed); cat"
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let driver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "grapheme-export-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "grapheme",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                    createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
            try driver.startIfNeeded()
            return Box(driver)
        }
        let driver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { driver.terminate() } }

        let expectedRows = Self.sequences.map { $0 + "|" }
        try await waitUntil { TerminalEngineActor.runSynchronously { driver.snapshot().map(Self.nonEmptyRows) ?? [] } == expectedRows }

        let snapshot = try XCTUnwrap(TerminalEngineActor.runSynchronously { driver.snapshot() })
        for (row, sequence) in Self.sequences.enumerated() {
            XCTAssertEqual(
                GhosttyTerminalSnapshotCellText.displayText(
                    for: snapshot.cells[row * snapshot.columns], cluster: snapshot.clusters[row * snapshot.columns]), sequence,
                "row \(row) lost part of a \(sequence.unicodeScalars.count)-scalar cluster on export")
        }
    }

    /// OSC 8 targets ride out on the same export. A snapshot must mark exactly the cells inside a
    /// link run, leave every other cell without one, and hand a cell that is both linked and
    /// multi-codepoint its cluster and its target together.
    func testEmbeddedSessionExportsHyperlinkTargets() async throws {
        let availability = GhosttyEmbeddedLocator.resolve(currentDirectoryPath: FileManager.default.currentDirectoryPath)
        guard case .available = availability else { throw XCTSkip("Ghostty runtime resources are unavailable for embedded renderer testing.") }

        // Two separate OSC 8 runs of the same URI. Each run gets its own implicit hyperlink id, so
        // the export's URI-bytes deduplication is what collapses them to one entry in the snapshot's
        // link table; an id-keyed table would emit two.
        let escape = "\u{1B}"
        let terminator = "\(escape)\\"
        let open = "\(escape)]8;;\(Self.linkURL)\(terminator)"
        let close = "\(escape)]8;;\(terminator)"
        let command = """
            stty -echo; printf '\\033[?2027h'; printf '%s\\n' '\(open)linked\(close) plain' '\(open)\(Self.family)\(close)'; cat
            """
        let driverBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedTerminalSessionDriver> in
            let driver = GhosttyEmbeddedTerminalSessionDriver(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "link-export-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "link",
                    workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: command,
                    createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell))
            try driver.startIfNeeded()
            return Box(driver)
        }
        let driver = driverBox.value
        defer { TerminalEngineActor.runSynchronously { driver.terminate() } }

        try await waitUntil {
            TerminalEngineActor.runSynchronously { driver.snapshot().map(Self.nonEmptyRows) ?? [] } == ["linked plain", Self.family]
        }
        let snapshot = try XCTUnwrap(TerminalEngineActor.runSynchronously { driver.snapshot() })

        // Only the cells the link run covers carry the target; the space and the word after the
        // closing sequence are outside it.
        let linkedRow = (0..<snapshot.columns).map { snapshot.linkURLs[$0] }
        XCTAssertEqual(Array(linkedRow.prefix("linked".count)), Array(repeating: Self.linkURL, count: "linked".count))
        XCTAssertTrue(linkedRow.dropFirst("linked".count).allSatisfy { $0 == nil }, "cells outside the link run carried a target")

        // A linked cell that is also a grapheme cluster keeps both.
        let clusterIndex = snapshot.columns
        XCTAssertEqual(
            GhosttyTerminalSnapshotCellText.displayText(for: snapshot.cells[clusterIndex], cluster: snapshot.clusters[clusterIndex]), Self.family)
        XCTAssertEqual(snapshot.linkURLs[clusterIndex], Self.linkURL)

        // Both runs resolve to the same string: the link table holds one entry for the URI.
        XCTAssertEqual(Set(snapshot.linkURLs.values), [Self.linkURL])
    }

    // MARK: - Harness

    /// Carries a non-Sendable engine-actor reference across an `await` gap in a nonisolated test body.
    /// The driver is only ever touched while isolated to `TerminalEngineActor`.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A row's text with the spacer cells a double-width glyph trails removed and trailing blanks
    /// dropped, so the result is what the program printed however the terminal split it into cells.
    private static func nonEmptyRows(of snapshot: GhosttyTerminalSnapshot) -> [String] {
        (0..<snapshot.rows).map { row -> String in
            var text = ""
            for column in 0..<snapshot.columns {
                let cell = snapshot.cells[row * snapshot.columns + column]
                guard cell.flags & GhosttyTerminalSnapshotGrid.spacerFlag == 0 else { continue }
                text +=
                    snapshot.clusters[row * snapshot.columns + column] ?? (cell.codepoint == 0 ? " " : String(UnicodeScalar(cell.codepoint) ?? " "))
            }
            return text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.filter { !$0.isEmpty }
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for the session to export the printed sequences")
    }
}
