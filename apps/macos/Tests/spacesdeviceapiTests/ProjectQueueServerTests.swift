#if canImport(Network) && canImport(Security)
    import Darwin
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// The project and workspace commands that do unbounded git, network, and filesystem work: an add-project
    /// preview that clones from a remote, a `spaces.yaml` import that reads out of the project's working
    /// tree, and a workspace create that runs `git worktree add` (checkout plus the repository's own
    /// `post-checkout` hook). Each of them runs for seconds or, against an unresponsive remote or volume, for
    /// as long as the operation takes.
    ///
    /// While one is in flight the daemon still has to answer every other connection: the app polls
    /// `.overview` several times a second, and a client whose input send timed out corroborates the link
    /// against a 2s deadline before tearing its stream down. Each test here stalls one of those commands and
    /// holds a second connection's `.overview` to well inside that deadline.
    ///
    /// The third such family, the project's `spaces.yaml` import/export, has no test here: its stall is a
    /// working tree on an unresponsive volume, and the read that would block is `String(contentsOf:)`,
    /// which refuses a fifo (the one in-process stand-in for a file that never answers) outright rather
    /// than blocking on it. Its lane assignment is covered by `SpacesDeviceAPICommandDescriptorTests`.
    final class ProjectQueueServerTests: XCTestCase {
        override class func tearDown() {
            try? FileManager.default.removeItem(at: projectQueueTestTLSRoot)
            super.tearDown()
        }

        /// `.previewGitProject` clones `spaces.yaml` out of the remote's default branch, and that clone has no
        /// timeout: a remote that accepts the connection and never answers holds the handler for as long as it
        /// stays silent. This stands one up, so the stall is the product's real one rather than a sleep.
        func testAGitProjectPreviewStalledOnAnUnreachableRemoteDoesNotDelayAnOverview() throws {
            try withTemporaryProfile {
                let remote = try StalledGitRemote()
                defer { remote.stop() }

                let fixture = try startServer(installationID: "project-clone-queue-test")
                defer { fixture.tearDown() }

                let previewClient = try SpacesDeviceAPIRequestSessionClient(resolver: fixture.resolver)
                defer { previewClient.cancel() }
                let previewFinished = expectation(description: "The stalled git preview eventually returns.")
                DispatchQueue.global().async {
                    _ = try? previewClient.send(
                        SpacesDeviceAPIRequest(
                            command: .previewGitProject(SpacesDeviceGitProjectPreviewRequest(gitURL: "git://127.0.0.1:\(remote.port)/stall.git")),
                            authToken: fixture.pairingStore.authToken, clientApp: fixture.clientApp))
                    previewFinished.fulfill()
                }
                XCTAssertTrue(remote.waitForConnection(timeout: 10), "The preview's clone must reach the stalled remote.")

                assertOverviewAnswersPromptly(fixture, "An overview poll must not wait behind a git preview stalled on an unreachable remote.")

                remote.stop()
                wait(for: [previewFinished], timeout: 20)
            }
        }

        /// `.createWorkspace` runs `git worktree add`, which checks the branch out and runs the repository's
        /// `post-checkout` hook to completion. A hook that parks is the deterministic stand-in for the seconds
        /// a checkout of a large repository takes.
        func testAWorkspaceCreateBlockedInGitDoesNotDelayAnOverview() throws {
            try withTemporaryProfile {
                let project = try seedGitProjectWithBlockingCheckoutHook()
                defer { project.release() }

                let fixture = try startServer(installationID: "workspace-create-queue-test")
                defer { fixture.tearDown() }

                let createClient = try SpacesDeviceAPIRequestSessionClient(resolver: fixture.resolver)
                defer { createClient.cancel() }
                let createFinished = expectation(description: "The blocked workspace create eventually returns.")
                DispatchQueue.global().async {
                    _ = try? createClient.send(
                        SpacesDeviceAPIRequest(
                            command: .createWorkspace(
                                SpacesDeviceWorkspaceCreateRequest(
                                    projectID: project.projectID, branch: "feature", baseBranch: nil, directoryName: nil)),
                            authToken: fixture.pairingStore.authToken, clientApp: fixture.clientApp))
                    createFinished.fulfill()
                }
                XCTAssertTrue(project.waitUntilCheckoutIsBlocked(timeout: 20), "The create must reach the blocking post-checkout hook.")

                assertOverviewAnswersPromptly(fixture, "An overview poll must not wait behind a workspace create blocked in git.")

                project.release()
                wait(for: [createFinished], timeout: 30)
            }
        }

        /// The shared assertion: one `.overview` on its own connection, timed. The 1.5s bound sits inside the
        /// 2s deadline a client applies to its link-corroboration probe, so an overview answered within it is
        /// answered in time to keep a healthy stream alive; the client's own timeout is looser so a failure
        /// reports the measured wait rather than a transport error.
        private func assertOverviewAnswersPromptly(_ fixture: ServerFixture, _ message: String) {
            do {
                let probeClient = try SpacesDeviceAPIRequestClient(resolver: fixture.resolver, timeoutSeconds: 10)
                let startedAt = Date()
                let response = try probeClient.request(
                    SpacesDeviceAPIRequest(command: .overview, authToken: fixture.pairingStore.authToken, clientApp: fixture.clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)
                XCTAssertTrue(response.ok, response.message)
                XCTAssertLessThan(elapsed, 1.5, message)
            } catch { XCTFail("The overview poll failed: \(error)") }
        }

        private struct ServerFixture {
            let server: SpacesDeviceAPIServer
            let resolver: SpacesDeviceEndpointResolver
            let pairingStore: AlwaysAuthorizedProjectQueuePairingStore
            let clientApp: SpacesDeviceClientApp

            func tearDown() { server.stop() }
        }

        private func startServer(installationID: String) throws -> ServerFixture {
            let identity = try projectQueueTestTLSIdentity()
            let pairingStore = AlwaysAuthorizedProjectQueuePairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            return ServerFixture(
                server: server,
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint),
                pairingStore: pairingStore,
                clientApp: SpacesDeviceClientApp(
                    installationID: installationID, bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0"))
        }

        /// A git project whose `post-checkout` hook touches a marker and then parks on a fifo, so the
        /// `git worktree add` inside `.createWorkspace` blocks until `release()` writes to it.
        private func seedGitProjectWithBlockingCheckoutHook() throws -> BlockingCheckoutProject {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let projectDir = root.appendingPathComponent("repo", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            try runGit(["init", "-q", "-b", "main", projectDir.path])
            try runGit(["-C", projectDir.path, "commit", "-q", "--allow-empty", "-m", "init"])

            let fifoPath = root.appendingPathComponent("checkout.fifo").path
            guard mkfifo(fifoPath, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let markerPath = root.appendingPathComponent("checkout.started").path
            let hookPath = projectDir.appendingPathComponent(".git/hooks/post-checkout").path
            try "#!/bin/sh\ntouch '\(markerPath)'\nread line < '\(fifoPath)'\n".write(toFile: hookPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)

            let projectID = "project-\(UUID().uuidString)"
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            try store.upsert(project: ProjectRecord(id: projectID, name: "Creatable", dir: projectDir.path, isGitRepo: true, defaultBranch: "main"))
            return BlockingCheckoutProject(projectID: projectID, fifoPath: fifoPath, markerPath: markerPath)
        }

        private func runGit(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            // A committer identity the repository does not have to supply, so this fixture works under any
            // developer's (or CI's) git configuration.
            process.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "Spaces Tests", "GIT_AUTHOR_EMAIL": "tests@usespaces.dev", "GIT_COMMITTER_NAME": "Spaces Tests",
                "GIT_COMMITTER_EMAIL": "tests@usespaces.dev",
            ]) { _, new in new }
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "ProjectQueueServerTests", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
            }
        }

        private func withTemporaryProfile(_ body: () throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
            let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            defer {
                if let originalDatabasePath {
                    setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
                } else {
                    unsetenv(SpacesProfile.databasePathEnvironmentVariable)
                }
                if let originalRuntimePath {
                    setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimePath, 1)
                } else {
                    unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
                }
                try? FileManager.default.removeItem(at: root)
            }
            try body()
        }
    }

    private let projectQueueTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-project-queue-tests-tls-\(UUID().uuidString)", isDirectory: true)

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair only
    /// needs a stable certificate to pin.
    private func projectQueueTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: projectQueueTestTLSRoot)
    }

    /// A TCP listener that completes the connection and then says nothing, which is what `git clone` waits on
    /// for its whole (absent) timeout: the client sends its request line and blocks for the ref advertisement.
    /// `stop()` closes both ends, which is what finally fails the clone and lets the stalled request return.
    private final class StalledGitRemote: @unchecked Sendable {
        let port: UInt16
        private let listenerFD: Int32
        private let lock = NSLock()
        private var acceptedFDs: [Int32] = []
        private var stopped = false
        private let connectionArrived = DispatchSemaphore(value: 0)

        init() throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard bound == 0, listen(fd, 8) == 0 else {
                let code = errno
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            var resolved = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &resolved) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            guard named == 0 else {
                let code = errno
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            listenerFD = fd
            port = UInt16(bigEndian: resolved.sin_port)
            Thread.detachNewThread { [self] in acceptLoop() }
        }

        /// Waits until `git` has actually connected, so a probe timed after this measures a stall that has
        /// really begun rather than a request still being sent.
        func waitForConnection(timeout: TimeInterval) -> Bool { connectionArrived.wait(timeout: .now() + timeout) == .success }

        func stop() {
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return
            }
            stopped = true
            let accepted = acceptedFDs
            acceptedFDs = []
            lock.unlock()
            close(listenerFD)
            for fd in accepted { close(fd) }
        }

        private func acceptLoop() {
            while true {
                let fd = accept(listenerFD, nil, nil)
                guard fd >= 0 else { return }
                lock.lock()
                let alreadyStopped = stopped
                if !alreadyStopped { acceptedFDs.append(fd) }
                lock.unlock()
                if alreadyStopped {
                    close(fd)
                    return
                }
                connectionArrived.signal()
            }
        }
    }

    /// A seeded git project whose `post-checkout` hook parks until released, so `git worktree add` inside
    /// `.createWorkspace` blocks there.
    private final class BlockingCheckoutProject: @unchecked Sendable {
        let projectID: String
        private let fifoPath: String
        private let markerPath: String
        private let lock = NSLock()
        private var released = false

        init(projectID: String, fifoPath: String, markerPath: String) {
            self.projectID = projectID
            self.fifoPath = fifoPath
            self.markerPath = markerPath
        }

        /// Polls for the marker the hook touches immediately before it parks, so the probe that follows is
        /// timed against a checkout that has genuinely stalled rather than a create still resolving branches.
        func waitUntilCheckoutIsBlocked(timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: markerPath) { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return false
        }

        /// Opens the write end without blocking, retrying while the hook is still between touching the
        /// marker and opening its read end. A blocking open would hang the test process instead of failing
        /// it if the hook died before parking.
        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                let fd = open(fifoPath, O_WRONLY | O_NONBLOCK)
                if fd >= 0 {
                    _ = "go\n".withCString { write(fd, $0, 3) }
                    close(fd)
                    return
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private final class AlwaysAuthorizedProjectQueuePairingStore: SpacesDevicePairingStoreProtocol {
        let authToken = "valid-token"

        func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
        func listDevices() throws -> [SpacesDevicePairedClient] { [] }
        func revoke(installationID _: String) throws {}
        func removeAll() throws {}
        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
            guard clientApp != nil, authToken == self.authToken else {
                throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
            }
        }
        func validate(clientApp _: SpacesDeviceClientApp) throws {}
    }
#endif
