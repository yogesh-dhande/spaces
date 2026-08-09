import XCTest

@testable import workspacecore

final class WorkspaceSetupDirectorySweepTests: XCTestCase {
    func testSweepRemovesOrphanedDirectoriesPastRetentionAndKeepsEverythingElse() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "workspace-setup-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let liveWorkspaceID = "live-workspace"
        let orphanedOldID = "orphaned-old"
        let orphanedRecentID = "orphaned-recent"
        for id in [liveWorkspaceID, orphanedOldID, orphanedRecentID] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(id, isDirectory: true), withIntermediateDirectories: true)
        }
        // A stray regular file directly under the sweep root (not a per-workspace directory) must
        // survive too: the sweep only classifies directories, and deleting an unrecognized file would
        // reach outside what this sweep owns.
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("stray-file", isDirectory: false))

        let now = Date()
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let oneDayAgo = now.addingTimeInterval(-1 * 24 * 60 * 60)
        // The live workspace's directory is also set older than the retention window, to prove age
        // never matters for a directory whose workspace still exists.
        try FileManager.default.setAttributes(
            [.modificationDate: eightDaysAgo], ofItemAtPath: root.appendingPathComponent(liveWorkspaceID, isDirectory: true).path)
        try FileManager.default.setAttributes(
            [.modificationDate: eightDaysAgo], ofItemAtPath: root.appendingPathComponent(orphanedOldID, isDirectory: true).path)
        try FileManager.default.setAttributes(
            [.modificationDate: oneDayAgo], ofItemAtPath: root.appendingPathComponent(orphanedRecentID, isDirectory: true).path)

        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: root.path, knownWorkspaceIDs: [liveWorkspaceID], now: now)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(remaining, [liveWorkspaceID, orphanedRecentID, "stray-file"])
    }

    func testSweepOnMissingDirectoryIsANoOp() {
        let missingPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("does-not-exist-\(UUID().uuidString)").path
        WorkspaceSetupDirectorySweep.sweep(workspaceSetupDirectory: missingPath, knownWorkspaceIDs: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
    }
}
