import XCTest

#if os(macOS)
    import Darwin

    @testable import spacesterminalcore

    final class CaddyServiceTests: XCTestCase {
        func testResolveExecutableURLPrefersEnvironmentOverride() throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "caddy-resolve-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("caddy", isDirectory: false)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let resolved = try CaddyService.resolveExecutableURL(environment: [CaddyService.executableEnvironmentVariable: executable.path])
            XCTAssertEqual(resolved.path, executable.path)
        }

        func testResolveExecutableURLFindsSpacesOwnedCaddyBesideRunningDaemon() throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "caddy-daemon-\(UUID().uuidString)", isDirectory: true)
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

        func testResolveExecutableURLFindsBundledCaddyThroughDaemonHelperSymlink() throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "caddy-helper-\(UUID().uuidString)", isDirectory: true)
            let resources = directory.appendingPathComponent("Applications/Spaces.app/Contents/Resources", isDirectory: true)
            let helperBin = directory.appendingPathComponent("Users/test/.spaces/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: helperBin, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let daemonTarget = resources.appendingPathComponent("spacesd", isDirectory: false)
            let caddyTarget = resources.appendingPathComponent("caddy", isDirectory: false)
            try Data("#!/bin/sh\n".utf8).write(to: daemonTarget)
            try Data("#!/bin/sh\n".utf8).write(to: caddyTarget)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemonTarget.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: caddyTarget.path)
            let daemonHelper = helperBin.appendingPathComponent("spacesd", isDirectory: false)
            try FileManager.default.createSymbolicLink(at: daemonHelper, withDestinationURL: daemonTarget)

            let resolved = try CaddyService.resolveExecutableURL(environment: ["_": daemonHelper.path])

            XCTAssertEqual(resolved.path, caddyTarget.path)
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
                for (name, value) in originalEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
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
                guard case CaddyServiceError.reloadFailed = error else { return XCTFail("Expected reloadFailed, got \(error)") }
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }

        func testSecureSocketRootIsPrivateToCurrentUser() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }

            let root = try CaddyService.secureSocketRoot(parentDirectory: base)

            var status = stat()
            XCTAssertEqual(lstat(root.path, &status), 0)
            XCTAssertEqual(status.st_mode & S_IFMT, S_IFDIR)
            XCTAssertEqual(status.st_uid, getuid())
            XCTAssertEqual(status.st_mode & 0o077, 0, "the admin socket root must deny group and other access")
        }

        func testSecureSocketRootRejectsWorldAccessibleDirectory() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            // Another local user could pre-create the predictable path with lax permissions; the
            // service must refuse it rather than bind the admin socket into a shared directory.
            let squatted = base.appendingPathComponent("spaces-caddy-sockets-\(getuid())", isDirectory: true)
            try FileManager.default.createDirectory(at: squatted, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])

            XCTAssertThrowsError(try CaddyService.secureSocketRoot(parentDirectory: base)) { error in
                guard case CaddyServiceError.socketRootUntrusted = error else { return XCTFail("Expected socketRootUntrusted, got \(error)") }
            }
        }

        func testSecureSocketRootRejectsSymlink() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caddy-root-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            // A symlink at the socket root would redirect the admin socket outside our owned tree.
            let target = base.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let link = base.appendingPathComponent("spaces-caddy-sockets-\(getuid())", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            XCTAssertThrowsError(try CaddyService.secureSocketRoot(parentDirectory: base)) { error in
                guard case CaddyServiceError.socketRootUntrusted = error else { return XCTFail("Expected socketRootUntrusted, got \(error)") }
            }
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
