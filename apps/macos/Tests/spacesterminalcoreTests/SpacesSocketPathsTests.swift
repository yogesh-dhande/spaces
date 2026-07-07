import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SpacesSocketPathsTests: XCTestCase {
    func testSecureSocketRootIsPrivateToCurrentUser() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "sockets-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let root = try SpacesSocketPaths.secureSocketRoot(parentDirectory: base)

        var status = stat()
        XCTAssertEqual(lstat(root.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(status.st_uid, getuid())
        XCTAssertEqual(status.st_mode & 0o077, 0, "the shared socket root must deny group and other access")
    }

    func testSecureSocketRootRejectsWorldAccessibleDirectory() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "sockets-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Another local user could pre-create the predictable path with lax permissions; the
        // helper must refuse it rather than bind any socket into a shared directory.
        let squatted = base.appendingPathComponent("spaces-sockets-\(getuid())", isDirectory: true)
        try FileManager.default.createDirectory(at: squatted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])

        XCTAssertThrowsError(try SpacesSocketPaths.secureSocketRoot(parentDirectory: base)) { error in
            guard case SpacesSocketPathsError.socketRootUntrusted = error else { return XCTFail("Expected socketRootUntrusted, got \(error)") }
        }
    }

    func testSecureSocketRootRejectsSymlink() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "sockets-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A symlink at the socket root would redirect sockets outside our owned tree.
        let target = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("spaces-sockets-\(getuid())", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SpacesSocketPaths.secureSocketRoot(parentDirectory: base)) { error in
            guard case SpacesSocketPathsError.socketRootUntrusted = error else { return XCTFail("Expected socketRootUntrusted, got \(error)") }
        }
    }
}
