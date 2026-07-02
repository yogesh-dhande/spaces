import XCTest
#if os(macOS)
import Darwin

@testable import spacesterminalcore

final class CaddyServiceTests: XCTestCase {
    func testResolveExecutableURLPrefersEnvironmentOverride() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("caddy", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try CaddyService.resolveExecutableURL(environment: [CaddyService.executableEnvironmentVariable: executable.path])
        XCTAssertEqual(resolved.path, executable.path)
    }

    func testResolveExecutableURLFindsSpacesOwnedCaddyBesideRunningDaemon() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-daemon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let genericExecutable = directory.appendingPathComponent("caddy", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: genericExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: genericExecutable.path)
        let executable = directory.appendingPathComponent("spaces-caddy", isDirectory: false)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let daemon = directory.appendingPathComponent("spacesd", isDirectory: false)
        let resolved = try CaddyService.resolveExecutableURL(environment: ["_": daemon.path])

        XCTAssertEqual(resolved.path, executable.path)
    }

    func testEnsureRunningDoesNotUnlinkLiveAdminSocketWhenReloadFails() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "caddy-live-socket-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeCaddy = directory.appendingPathComponent("caddy", isDirectory: false)
        try Data(
            """
            #!/bin/sh
            if [ "$1" = "run" ]; then
              /usr/bin/touch "$SPACES_TEST_CADDY_RUN_MARKER"
            fi
            exit 1
            """.utf8
        ).write(to: fakeCaddy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCaddy.path)

        let marker = directory.appendingPathComponent("started", isDirectory: false)
        let environmentKeys = [
            SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable,
            CaddyService.executableEnvironmentVariable, "SPACES_TEST_CADDY_RUN_MARKER",
        ]
        let originalEnvironment = environmentKeys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (name, value) in originalEnvironment {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
            SpacesProfile.resetCacheForTesting()
        }
        setenv(SpacesProfile.databasePathEnvironmentVariable, directory.appendingPathComponent("spaces.db").path, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, directory.path, 1)
        setenv(CaddyService.executableEnvironmentVariable, fakeCaddy.path, 1)
        setenv("SPACES_TEST_CADDY_RUN_MARKER", marker.path, 1)
        SpacesProfile.resetCacheForTesting()

        let socketPath = try CaddyService.adminSocketPath()
        let socketFD = try bindUnixSocket(at: socketPath)
        defer {
            close(socketFD)
            unlink(socketPath)
        }

        XCTAssertThrowsError(try CaddyService.ensureRunning(configJSON: Data("{}".utf8), timeout: 0.1)) { error in
            guard case CaddyServiceError.reloadFailed = error else {
                return XCTFail("Expected reloadFailed, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw currentPOSIXError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        try path.withCString { pathPointer in
            guard strlen(pathPointer) < maxPathLength else {
                close(fd)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination -> Void in
                    _ = strncpy(destination, pathPointer, maxPathLength - 1)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = currentPOSIXError()
            close(fd)
            throw error
        }
        guard listen(fd, 1) == 0 else {
            let error = currentPOSIXError()
            close(fd)
            throw error
        }
        return fd
    }

    private func currentPOSIXError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
#endif
