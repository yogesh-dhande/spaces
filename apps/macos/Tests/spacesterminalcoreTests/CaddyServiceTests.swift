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

        /// Reload against a confirmed-live admin socket ("confirmed-live" here means the socket has an
        /// open owner `lsof` can see, which is why the test binds it directly rather than relying on the
        /// fake `caddy` binary — the reload/run subcommands are short-lived children, not something that
        /// can genuinely hold the socket open the way a real Caddy would) must not throw: `ensureRunning`
        /// stops the wedged instance and starts fresh with the same config instead of leaving stale
        /// routes served indefinitely (issue #422).
        func testEnsureRunningRecoversFromReloadFailureAgainstLiveOwner() throws {
            let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
                "caddy-live-socket-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }

            let fakeCaddy = directory.appendingPathComponent("caddy", isDirectory: false)
            let runMarker = directory.appendingPathComponent("started", isDirectory: false)
            try Data(
                """
                #!/bin/sh
                if [ "$1" = "run" ]; then
                  /usr/bin/touch "$SPACES_TEST_CADDY_RUN_MARKER"
                  /usr/bin/touch "$SPACES_TEST_CADDY_SOCKET"
                  exit 0
                fi
                if [ "$1" = "reload" ]; then
                  echo "sample_upstream: dial tcp 127.0.0.1:9: connect: connection refused" 1>&2
                  exit 1
                fi
                exit 0
                """.utf8
            ).write(to: fakeCaddy)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCaddy.path)

            let environmentKeys = [
                SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable,
                CaddyService.executableEnvironmentVariable, "SPACES_TEST_CADDY_RUN_MARKER", "SPACES_TEST_CADDY_SOCKET",
            ]
            let originalEnvironment = environmentKeys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            defer {
                for (name, value) in originalEnvironment { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
                SpacesProfile.resetCacheForTesting()
            }
            setenv(SpacesProfile.databasePathEnvironmentVariable, directory.appendingPathComponent("spaces.db").path, 1)
            setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, directory.path, 1)
            setenv(CaddyService.executableEnvironmentVariable, fakeCaddy.path, 1)
            setenv("SPACES_TEST_CADDY_RUN_MARKER", runMarker.path, 1)
            SpacesProfile.resetCacheForTesting()

            let socketPath = try CaddyService.adminSocketPath()
            setenv("SPACES_TEST_CADDY_SOCKET", socketPath, 1)
            let socketFD = try bindUnixSocket(at: socketPath)
            defer {
                // `stop()` unlinks the path as the last rung of its ladder regardless of whether anything
                // answered `caddy stop`, and the fake `caddy`'s `run` branch then recreates a plain file
                // at the same path — a different filesystem entry from the one `socketFD` was bound to.
                // Closing `socketFD` is safe either way: it only releases this test's own descriptor and
                // never touches whatever now occupies the path.
                close(socketFD)
                unlink(socketPath)
            }

            let launchedNewInstance = try CaddyService.ensureRunning(configJSON: Data("{}".utf8), timeout: 2)

            XCTAssertTrue(launchedNewInstance)
            XCTAssertTrue(FileManager.default.fileExists(atPath: runMarker.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        }

        func testReloadFailedErrorDescriptionCarriesExitStatusAndStderr() throws {
            let error = CaddyServiceError.reloadFailed(
                configPath: "/tmp/caddy.json", exitStatus: 1, stderr: "sample_upstream: dial tcp 127.0.0.1:9: connect: connection refused")
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("exit 1"), description)
            XCTAssertTrue(description.contains("connection refused"), description)

            let timedOutError = CaddyServiceError.reloadFailed(configPath: "/tmp/caddy.json", exitStatus: nil, stderr: "")
            XCTAssertTrue(try XCTUnwrap(timedOutError.errorDescription).contains("timed out"))
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
