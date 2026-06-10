import AppKit
import Foundation
import systembridge
import workspacecore

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

func makeTemporaryStore() throws -> SQLiteStore {
    let dir = try makeTempDirectory()
    let dbURL = dir.appendingPathComponent("spaces-test.db")
    return try SQLiteStore(path: dbURL.path)
}

func makeProjectRecord(id: String = UUID().uuidString, dir: String) -> ProjectRecord {
    ProjectRecord(
        id: id, name: "Project", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
        browserSessions: [])
}

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, title: String, dir: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: id, projectID: projectID, title: title, dir: dir, dirname: nil, branch: nil, isDefault: false, isArchived: false, isRunning: false,
        lastLaunchedAt: nil)
}

func makeComputeHostRecord(id: String = UUID().uuidString, name: String = "Builder") -> ComputeHostRecord {
    let hostSlug = name.lowercased().replacingOccurrences(of: " ", with: "-")
    return ComputeHostRecord(
        id: id, name: name, sshHost: "\(hostSlug).internal", sshUser: "spaces", sshPort: 22, workspaceRoot: "/srv/spaces",
        daemonEndpoint: SpacesDaemonEndpoint(host: "\(hostSlug).lan", port: 8443, certificateFingerprint: "SHA256:abcdef"),
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
}

final class MockTerminalFocusPulseController: TerminalFocusPulseControlling, @unchecked Sendable {
    var pulseCallCount = 0
    var pulsedWindowIDs: [Int] = []
    var pulseColors: [(r: Int, g: Int, b: Int)] = []

    func pulse(windowID: Int, color: (r: Int, g: Int, b: Int), yabai _: YabaiAdapter) {
        pulseCallCount += 1
        pulsedWindowIDs.append(windowID)
        pulseColors.append(color)
    }
}
