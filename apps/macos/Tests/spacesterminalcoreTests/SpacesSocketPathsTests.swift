import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class SpacesSocketPathsTests: XCTestCase {
    /// The shared root is validated by name, because a test host resolves a root of its own (see
    /// `testTestHostGetsItsOwnRootBesideTheSharedOne`) and the hijack refusal has to be asserted against
    /// the name every real Spaces process binds under.
    private var sharedRootName: String { "spaces-sockets-\(getuid())" }

    private func makeBaseDirectory() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "sockets-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    func testSecureSocketRootIsPrivateToCurrentUser() throws {
        let base = try makeBaseDirectory()

        let root = try SpacesSocketPaths.validatedRoot(named: sharedRootName, in: base)

        var status = stat()
        XCTAssertEqual(lstat(root.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(status.st_uid, getuid())
        XCTAssertEqual(status.st_mode & 0o077, 0, "the shared socket root must deny group and other access")
    }

    func testSecureSocketRootRejectsWorldAccessibleDirectory() throws {
        let base = try makeBaseDirectory()
        // Another local user could pre-create the predictable path with lax permissions; the
        // helper must refuse it rather than bind any socket into a shared directory.
        let squatted = base.appendingPathComponent(sharedRootName, isDirectory: true)
        try FileManager.default.createDirectory(at: squatted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])

        XCTAssertThrowsError(try SpacesSocketPaths.validatedRoot(named: sharedRootName, in: base)) { error in
            guard case SpacesSocketPathsError.socketRootUntrusted = error else { return XCTFail("Expected socketRootUntrusted, got \(error)") }
        }
    }

    func testSecureSocketRootRejectsSymlink() throws {
        let base = try makeBaseDirectory()
        // A symlink at the socket root would redirect sockets outside our owned tree.
        let target = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent(sharedRootName, isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SpacesSocketPaths.validatedRoot(named: sharedRootName, in: base)) { error in
            guard case SpacesSocketPathsError.socketRootUntrusted = error else { return XCTFail("Expected socketRootUntrusted, got \(error)") }
        }
    }

    /// A test process must not leave socket entries in the directory every real daemon on the machine
    /// binds into. Its entries are named from a hash of a throwaway profile root, so once the fixture
    /// deletes that profile nothing can attribute them back to anything and reclaim them (#685); a root
    /// of the process's own is what makes them reclaimable at all.
    func testTestHostGetsItsOwnRootBesideTheSharedOne() throws {
        let base = try makeBaseDirectory()

        let root = try SpacesSocketPaths.secureSocketRoot(parentDirectory: base)

        XCTAssertEqual(root.lastPathComponent, "spaces-t\(getuid())-\(getpid())")
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL.path, base.standardizedFileURL.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: base.appendingPathComponent(sharedRootName).path),
            "a test host must not even create the shared root, let alone bind in it")
        // The whole point of the shared root is the 104-byte AF_UNIX cap, so a test host's root must not
        // spend more of that budget than the root it stands in for, or a bind the product would accept
        // could fail only under test (or the reverse).
        XCTAssertLessThanOrEqual(root.lastPathComponent.utf8.count, sharedRootName.utf8.count)
    }

    /// A test process killed mid-run never runs its exit handler, so its root has to be reclaimable by a
    /// later run. Reclaim is by process identity, never by age, so a root belonging to a suite running
    /// concurrently is left alone however old it is.
    func testAbandonedRootOfAnExitedProcessIsReclaimedAndALiveOnesIsKept() throws {
        let base = try makeBaseDirectory()
        let exitedPID = try exitedProcessID()
        let abandoned = base.appendingPathComponent("spaces-t\(getuid())-\(exitedPID)", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: abandoned.appendingPathComponent("stale.sock").path, contents: nil))
        // launchd: always running, and owned by root, so it also covers the EPERM answer to `kill(pid, 0)`.
        let live = base.appendingPathComponent("spaces-t\(getuid())-1", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        // The shared root, and anything a daemon binds in it, must never be a reclaim candidate.
        let sharedRoot = try SpacesSocketPaths.validatedRoot(named: sharedRootName, in: base)
        XCTAssertTrue(FileManager.default.createFile(atPath: sharedRoot.appendingPathComponent("service-0123456789abcdef.sock").path, contents: nil))

        _ = try SpacesSocketPaths.secureSocketRoot(parentDirectory: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sharedRoot.appendingPathComponent("service-0123456789abcdef.sock").path))
    }

    /// A suite that pins `SPACESD_EXECUTABLE` runs the real daemon, and `ensureRunning` spawns it as a
    /// child. That child cannot derive the suite's root, since it is not this process, so the root has to
    /// travel with the spawn, or the daemon binds a socket the suite never polls and the suite times out
    /// waiting for a daemon that is running.
    func testSpawnedChildResolvesTheSameRootAsItsTestHost() throws {
        // This process's real root, not one under a temporary base: propagation reports what the launcher
        // would actually hand a child. It is swept by the process-exit handler that owns it, so this test
        // leaves it in place for whatever else in this process is bound under it.
        let hostRoot = try SpacesSocketPaths.secureSocketRoot()

        let childEnvironment = try SpacesSocketPaths.environmentPropagatingSocketRoot(["PATH": "/usr/bin"])

        XCTAssertEqual(childEnvironment[SpacesSocketPaths.socketRootEnvironmentVariable], hostRoot.path)
        XCTAssertEqual(childEnvironment["PATH"], "/usr/bin", "propagation must add one variable, not replace the environment")
        // Resolved the way the spawned daemon resolves it: a different process, and not a test host.
        let child = SpacesSocketPaths.resolveSocketRoot(
            parentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            inheritedSocketRootPath: childEnvironment[SpacesSocketPaths.socketRootEnvironmentVariable], isTestHost: false, uid: getuid(),
            pid: getpid() + 1)
        XCTAssertEqual(child.url.path, hostRoot.path)
        // The host owns the reclaim: the child must not sweep a root it did not create.
        XCTAssertEqual(child.kind, .inheritedTestProcess)
    }

    /// The variable exists for spawned test children only. A real `spacesd` must keep binding in the
    /// shared root whatever a stray binding in its environment says, since a root it can be talked out of
    /// is a daemon no client can find.
    func testProductionProcessIgnoresASocketRootBindingItDidNotEarn() throws {
        let base = try makeBaseDirectory()

        for strayValue in ["/tmp/attacker-owned", "", "/tmp/spaces-t\(getuid() &+ 1)-4242", "/tmp/spaces-t\(getuid())-notapid"] {
            let resolved = SpacesSocketPaths.resolveSocketRoot(
                parentDirectory: base, inheritedSocketRootPath: strayValue, isTestHost: false, uid: getuid(), pid: getpid())
            XCTAssertEqual(resolved.url.lastPathComponent, sharedRootName, "stray value \(strayValue) moved a production socket root")
            XCTAssertEqual(resolved.kind, .shared)
        }
    }

    /// A pid that named a real process and no longer does, which is what an abandoned root carries.
    private func exitedProcessID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }
}
