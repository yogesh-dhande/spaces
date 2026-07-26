import Darwin
import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

/// The daemon binds two Unix sockets per terminal session — the control socket and the render-state
/// subscription socket — and every session eventually ends. A descriptor that outlives its session
/// therefore accumulates for the whole daemon lifetime and is bounded only by the process descriptor
/// limit, after which the daemon can open neither sockets nor its SQLite database. These tests assert
/// the descriptors are released at teardown, keyed on the session's own socket paths so a concurrently
/// running test's descriptors cannot mask or fake the result.
final class SessionSocketDescriptorLifetimeTests: XCTestCase {
    private var originalDatabasePath: String?
    private var originalRuntimeDirectory: String?
    private var databaseRoot: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        databaseRoot = root
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }

    override func tearDownWithError() throws {
        if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
        if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
        if let databaseRoot { try? FileManager.default.removeItem(at: databaseRoot) }
        databaseRoot = nil
        originalDatabasePath = nil
        originalRuntimeDirectory = nil
        try super.tearDownWithError()
    }

    /// Carries the engine-actor-isolated session host across the `await` in the test body; it is only
    /// ever touched while isolated to `TerminalEngineActor`.
    private final class Box<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    func testTerminatingSessionReleasesItsControlAndSubscriptionSocketDescriptors() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = TerminalSessionPaths(rootDirectory: root.path)
        try paths.ensureDirectories()
        let sessionSocketPaths = [paths.controlSocketPath, paths.subscriptionSocketPath]

        let hostBox = try await TerminalEngineActor.run { () -> Box<GhosttyEmbeddedSessionHost> in
            let host = GhosttyEmbeddedSessionHost(
                launchConfiguration: TerminalSessionLaunchConfiguration(
                    sessionID: "socket-descriptor-lifetime-\(UUID().uuidString)", backend: .ghosttyEmbedded, title: "shell", workingDirectory: "/tmp",
                    shell: "/bin/zsh", command: nil, createdAt: "2026-07-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try host.startIfNeeded()
            return Box(host)
        }
        XCTAssertEqual(
            Self.openDescriptorCount(forSocketPaths: sessionSocketPaths), sessionSocketPaths.count,
            "A started session must hold exactly one descriptor per per-session socket.")

        await TerminalEngineActor.run { hostBox.value.terminate() }

        try await waitUntil(timeout: 10) { Self.openDescriptorCount(forSocketPaths: sessionSocketPaths) == 0 }
    }

    func testStoppingControlServerReleasesItsDescriptorAfterTheServerIsDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = root.appendingPathComponent("control.sock").path
        let queue = DispatchQueue(label: "session-socket-descriptor-lifetime-test")

        // The daemon stops a session's control server and releases it in the same breath, so the
        // descriptor must be closed without the server object being alive to do it.
        var server: TerminalControlServer? = TerminalControlServer(socketPath: socketPath, queue: queue) { _ in
            TerminalControlResponse(ok: true, message: "ack")
        }
        try server?.start()
        XCTAssertEqual(Self.openDescriptorCount(forSocketPaths: [socketPath]), 1)
        server?.stop()
        server = nil

        try await waitUntil(timeout: 10) { Self.openDescriptorCount(forSocketPaths: [socketPath]) == 0 }
    }

    /// How many descriptors this process holds on Unix sockets bound to `socketPaths`. Reads the
    /// kernel's own descriptor table rather than the filesystem, so it still sees a descriptor whose
    /// socket file was unlinked at teardown — which is exactly the leaked state being asserted against.
    private static func openDescriptorCount(forSocketPaths socketPaths: [String]) -> Int {
        let pid = getpid()
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return 0 }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride)
        let usedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bufferSize)
        guard usedBytes > 0 else { return 0 }

        let wanted = Set(socketPaths)
        var matches = 0
        for descriptor in descriptors.prefix(Int(usedBytes) / MemoryLayout<proc_fdinfo>.stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socketInfo = socket_fdinfo()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read > 0, socketInfo.psi.soi_family == AF_UNIX else { continue }
            let address = socketInfo.psi.soi_proto.pri_un.unsi_addr.ua_sun
            let boundPath = withUnsafePointer(to: address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: address.sun_path)) { String(cString: $0) }
            }
            if wanted.contains(boundPath) { matches += 1 }
        }
        return matches
    }

    private func waitUntil(
        timeout: TimeInterval, pollInterval: TimeInterval = 0.02, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        XCTFail("Timed out waiting for the session socket descriptors to be released.", file: file, line: line)
        throw NSError(domain: "SessionSocketDescriptorLifetimeTests", code: 1)
    }
}
