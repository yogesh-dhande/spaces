import XCTest

@testable import workspacecore

final class WorkspaceSetupDirectorySweepTests: XCTestCase {
    private let orphanMarkerFileName = ".orphaned"

    /// The first time a directory is seen as orphaned it only gets marked, never deleted: age is
    /// tracked from the marker's own mtime (the first-seen timestamp), not the directory's mtime,
    /// since writing/truncating setup.log never updates the parent directory's mtime.
    func testFirstPassOnAnOrphanCreatesMarkerButDoesNotDelete() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphanID = "freshly-orphaned"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(orphanID, isDirectory: true), withIntermediateDirectories: true)

        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: root.path, knownWorkspaceIDs: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphanID, isDirectory: true).path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(orphanID).appendingPathComponent(orphanMarkerFileName).path))
    }

    func testOrphanWithMarkerOlderThanRetentionIsDeleted() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphanID = "orphaned-old"
        let directoryPath = root.appendingPathComponent(orphanID, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: true)
        try writeMarker(in: directoryPath, age: -8 * 24 * 60 * 60)

        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: root.path, knownWorkspaceIDs: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryPath.path))
    }

    func testOrphanWithMarkerYoungerThanRetentionIsKept() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let orphanID = "orphaned-recent"
        let directoryPath = root.appendingPathComponent(orphanID, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: true)
        try writeMarker(in: directoryPath, age: -1 * 24 * 60 * 60)

        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: root.path, knownWorkspaceIDs: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryPath.path))
    }

    /// A workspace resurrected after being marked orphaned (e.g. discovery re-imports it between
    /// daemon startups) must have its stale marker removed so a later orphaning restarts the
    /// retention clock instead of inheriting the old first-seen timestamp.
    func testLiveWorkspaceWithStaleMarkerHasMarkerRemovedAndSurvives() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let liveID = "resurrected-workspace"
        let directoryPath = root.appendingPathComponent(liveID, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: true)
        try writeMarker(in: directoryPath, age: -8 * 24 * 60 * 60)

        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: root.path, knownWorkspaceIDs: [liveID])

        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryPath.appendingPathComponent(orphanMarkerFileName).path))
    }

    func testStrayFileAtSweepRootIsUntouched() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let strayFile = root.appendingPathComponent("stray-file", isDirectory: false)
        try Data("not a directory".utf8).write(to: strayFile)

        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: root.path, knownWorkspaceIDs: [])

        XCTAssertTrue(FileManager.default.fileExists(atPath: strayFile.path))
    }

    func testSweepOnMissingDirectoryIsANoOp() {
        let missingPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("does-not-exist-\(UUID().uuidString)").path
        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: missingPath, knownWorkspaceIDs: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
    }

    private func makeSweepRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "workspace-setup-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes an `.orphaned` marker inside `directory` and backdates its mtime by `age` seconds
    /// (negative = in the past), simulating a marker created `age` seconds ago by an earlier sweep.
    private func writeMarker(in directory: URL, age: TimeInterval) throws {
        let markerPath = directory.appendingPathComponent(orphanMarkerFileName, isDirectory: false)
        try Data().write(to: markerPath)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(age)], ofItemAtPath: markerPath.path)
    }
}
