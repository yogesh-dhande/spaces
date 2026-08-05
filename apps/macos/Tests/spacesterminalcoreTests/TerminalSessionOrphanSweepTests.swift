import Foundation
import XCTest

@testable import spacesterminalcore

/// Validates the daemon-owned orphan sweep that reclaims on-disk terminal state the row-driven collector
/// can never see: abandoned session directories (no `terminal_sessions` row) and crash-stranded
/// `output.log.trim` temp files. It must delete only entries provably abandoned — past the grace period
/// and absent from both the known and active session sets — and must leave everything else, including
/// non-directory strays, untouched.
final class TerminalSessionOrphanSweepTests: XCTestCase {
    private var originalRuntimeDirectory: String?
    private var originalDatabasePath: String?
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db", isDirectory: false).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private let now = Date()
    private let gracePeriod: TimeInterval = 3600
    private var oldMtime: Date { now.addingTimeInterval(-7200) }
    private var freshMtime: Date { now.addingTimeInterval(-60) }

    /// Creates a directory `name` directly under the sessions root and stamps its modification date to
    /// `age` seconds before `now`, so its position relative to the grace period is deterministic.
    @discardableResult private func makeSessionDirectory(_ name: String, age: TimeInterval) throws -> String {
        let path = URL(fileURLWithPath: try TerminalSessionPaths.sessionsRootDirectory()).appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
        return path
    }

    private func writeFile(_ path: String, contents: String, mtime: Date) throws {
        FileManager.default.createFile(atPath: path, contents: Data(contents.utf8))
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
    }

    private func sweep(
        known: Set<String> = [], active: Set<String> = [], fileManager: FileManager = .default, onFailure: (String, any Error) -> Void = { _, _ in }
    ) throws -> [String] {
        try TerminalSessionOrphanSweep.sweep(
            knownSessionIDs: known, activeSessionIDs: active, gracePeriod: gracePeriod, fileManager: fileManager, now: now, onFailure: onFailure)
    }

    /// Fails `removeItem` for the one entry whose path contains `failingName`, delegating every other call
    /// (including other removals, `attributesOfItem`, and `createDirectory`) to the real `FileManager`.
    /// Mirrors the garbage collector tests' harness so a sweep with multiple candidates can exercise "only
    /// the targeted removal fails, the rest still complete".
    private final class RemoveItemThrowingFileManager: FileManager {
        struct RemovalFailure: Error {}
        private let failingName: String

        init(failingName: String) {
            self.failingName = failingName
            super.init()
        }

        override func removeItem(atPath path: String) throws {
            guard path.contains(failingName) else {
                try super.removeItem(atPath: path)
                return
            }
            throw RemovalFailure()
        }
    }

    // An orphan directory past the grace period is reclaimed; one still inside the grace period survives.
    func testRemovesOldOrphanKeepsFreshOrphan() throws {
        let old = try makeSessionDirectory("old-orphan", age: 7200)
        let fresh = try makeSessionDirectory("fresh-orphan", age: 60)

        let removed = try sweep()

        XCTAssertEqual(removed, [old], "Only the orphan past the grace period must be reclaimed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh), "An orphan inside the grace period may be a creation racing the sweep.")
    }

    // A directory named by a known or an active session ID is a real session and must survive regardless
    // of age; the active set guards live in-memory cores whose row has not committed yet.
    func testKeepsKnownAndActiveDirectoriesRegardlessOfAge() throws {
        let known = try makeSessionDirectory("known", age: 7200)
        let active = try makeSessionDirectory("active", age: 7200)

        let removed = try sweep(known: ["known"], active: ["active"])

        XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: known), "A directory in the known set must never be deleted.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: active), "A directory in the active set must never be deleted.")
    }

    // A crash-stranded output.log.trim past the grace period inside a real session dir is removed, while
    // output.log and the dir itself survive; an in-flight (fresh) trim is left alone.
    func testRemovesStaleTrimFileButKeepsTranscriptAndFreshTrim() throws {
        let staleDir = try makeSessionDirectory("has-stale-trim", age: 7200)
        let outputPath = URL(fileURLWithPath: staleDir).appendingPathComponent("output.log").path
        let staleTrimPath = URL(fileURLWithPath: staleDir).appendingPathComponent("output.log.trim").path
        try writeFile(outputPath, contents: "transcript", mtime: freshMtime)
        try writeFile(staleTrimPath, contents: "leftover", mtime: oldMtime)

        let freshDir = try makeSessionDirectory("has-fresh-trim", age: 7200)
        let freshTrimPath = URL(fileURLWithPath: freshDir).appendingPathComponent("output.log.trim").path
        try writeFile(freshTrimPath, contents: "in-flight", mtime: freshMtime)

        let removed = try sweep(known: ["has-stale-trim", "has-fresh-trim"])

        XCTAssertEqual(removed, [staleTrimPath], "Only the crash-stranded trim temp must be reclaimed.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTrimPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath), "The live transcript must never be touched.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleDir), "A real session directory must never be deleted.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshTrimPath), "An in-flight trim inside the grace period must survive.")
    }

    // A removal failure on one entry is contained: it is reported through onFailure and the sweep still
    // reclaims the other candidates.
    func testContainsRemovalFailureAndSweepsRemainingEntries() throws {
        let leaky = try makeSessionDirectory("leaky-orphan", age: 7200)
        let clean = try makeSessionDirectory("clean-orphan", age: 7200)
        var failures: [String] = []

        let removed = try sweep(
            fileManager: RemoveItemThrowingFileManager(failingName: "leaky-orphan"), onFailure: { path, _ in failures.append(path) })

        XCTAssertEqual(removed, [clean], "The sweep must continue past the failed entry and reclaim the rest.")
        XCTAssertEqual(failures, [leaky], "The failure must be reported to the caller so it can be logged.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaky), "The undeletable orphan is left for the next sweep to retry.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean))
    }

    // A missing sessions root is not an error: the sweep has nothing to iterate and returns empty.
    func testMissingSessionsRootReturnsEmpty() throws {
        var removed: [String] = []
        XCTAssertNoThrow(removed = try sweep())
        XCTAssertTrue(removed.isEmpty)
    }

    // A non-directory stray at the root is not a session dir the sweep owns; it must be left untouched even
    // when past the grace period, while orphan directories around it are still reclaimed.
    func testLeavesNonDirectoryStrayUntouched() throws {
        let strayPath = URL(fileURLWithPath: try TerminalSessionPaths.sessionsRootDirectory()).appendingPathComponent("stray.txt").path
        try writeFile(strayPath, contents: "not a session", mtime: oldMtime)
        let orphan = try makeSessionDirectory("orphan", age: 7200)

        let removed = try sweep()

        XCTAssertEqual(removed, [orphan], "Only the orphan directory is reclaimed; the stray file is not owned by the sweep.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayPath), "A non-directory stray at the root must be left alone.")
    }
}
