import Foundation
import Testing

@testable import spacesdeviceapi

/// Round-19: `atomicallyWriteWorkspaceFile`'s rename-into-place replaces the target file's inode, which is
/// already known (and accepted, see that method's doc comment) to drop custom xattrs. POSIX permissions are
/// a different question: git tracks the exec bit, so silently losing it on a save would surface as a
/// spurious mode change and a broken script. This calls the real write path directly (not a
/// reimplementation of its logic) because the existing end-to-end `workspaceFileWrite` coverage in
/// `WorkspaceGitServerTests` drives it over the real TLS request/response path, which needs
/// `Network`/`Security` and so cannot run on the Linux daemon build — this is the only route this
/// regression can be checked on both platforms the write path actually ships on.
@Suite struct WorkspaceFileWriteModePreservationTests {
    @Test func anExistingFilesPOSIXModeSurvivesAnAtomicOverwrite() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-mode-preserve-\(UUID().uuidString).txt"
        ).path
        try "original content".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try SpacesDeviceAPIServer.atomicallyWriteWorkspaceFile(Data("updated content".utf8), to: path)

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode & 0o777 == 0o755)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "updated content")
    }
}
