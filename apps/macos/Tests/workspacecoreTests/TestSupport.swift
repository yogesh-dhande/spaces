import AppKit
import Darwin
import Foundation
import XCTest
import spacesterminalcore
import systembridge
import workspacecore

/// Tracks every directory `makeTempDirectory()` creates in this process and removes them all when the
/// process exits (issue #520: these fixtures otherwise leak into the system temp directory without bound).
///
/// A process-exit sweep, not per-test `addTeardownBlock`, is the right hook here because `makeTempDirectory()`
/// is a bare free function called from far more than XCTestCase test methods: `GitTestFixtures.swift`'s
/// `GitTemplateRepoCache` caches one template repo per initial branch for the whole process (deliberately —
/// rebuilding it per test would defeat the cache), and its `makeTempGitRepo`/`makeGitHangingInsideDirectory`
/// are free functions with no `self`; `WorktreeDiscoveryServiceTests.swift` is a Swift Testing `struct`, which
/// likewise has no `XCTestCase` to register teardown on. `atexit` is process-global, so it reaches every
/// caller uniformly without needing call-site changes anywhere. Removing per-directory disk sooner (at each
/// test's teardown, where that's available) is a nice-to-have, not what the leak report calls out — the
/// problem is directories outliving the process indefinitely, which this backstop already closes.
private final class TemporaryDirectoryTracker: @unchecked Sendable {
    static let shared = TemporaryDirectoryTracker()

    private let lock = NSLock()
    private var directories: [URL] = []
    private var registered = false

    func track(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        directories.append(url)
        guard !registered else { return }
        registered = true
        atexit {
            TemporaryDirectoryTracker.shared.sweep()
        }
    }

    private func sweep() {
        lock.lock()
        let toRemove = directories
        directories = []
        lock.unlock()
        for url in toRemove {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    TemporaryDirectoryTracker.shared.track(base)
    return base
}

extension XCTestCase {
    /// Points the profile environment at `databasePath` for the rest of this test, restoring the previous
    /// values in a teardown block so the override never leaks into later tests in the same process.
    ///
    /// Anything a test reaches — the workspace store's migration authorization, terminal-session
    /// persistence, runtime paths — resolves the active profile from `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`,
    /// so passing an explicit database path to one component is not isolation on its own.
    func bindSpacesProfileForTest(databasePath: String) {
        let runtimePath = URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("runtime", isDirectory: true).path
        let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        let originalValues = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        addTeardownBlock { for (name, value) in originalValues { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        setenv(SpacesProfile.databasePathEnvironmentVariable, databasePath, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimePath, 1)
    }

    /// Binds the profile environment to a fresh throwaway profile for the rest of this test. Use it in
    /// `setUpWithError` so no code path a test reaches — including work its background queues finish
    /// later — can resolve the developer's profile.
    func useIsolatedSpacesProfile() throws {
        bindSpacesProfileForTest(databasePath: try makeTempDirectory().appendingPathComponent("spaces.db").path)
    }

    /// A store backed by a fresh temporary database, with the profile environment scoped to this test.
    func makeTemporaryStore() throws -> SQLiteStore {
        _ = installHermeticGitEnvironment
        let dir = try makeTempDirectory()
        let databasePath = dir.appendingPathComponent("spaces-test.db").path
        bindSpacesProfileForTest(databasePath: databasePath)
        return try SQLiteStore(path: databasePath)
    }
}

/// Drops this process's placeholder reservations and runtime-start holds on `ports`, so a test's ports
/// never outlive it in the shared `PortReserver`. `sync` is the only mutator that both closes a
/// placeholder and clears a hold, and it clears holds process-wide, which is exact here because tests
/// run one at a time and no other component in the test process takes holds.
func clearPortReservationsForTest(_ ports: some Sequence<Int>) {
    PortReserver.shared.sync(desiredPorts: PortReserver.shared.reservedPorts().subtracting(ports))
}

/// Binds one placeholder-shaped probe socket with the exact options `PortReserver.bindSocket` uses
/// (`SO_REUSEPORT`, `INADDR_ANY`, never listened on), so "bindable" here means the same thing it means
/// for the real placeholder reservations these tests exercise. Returns the bound descriptor, or nil if
/// the port is already taken.
private func bindTestPlaceholderSocket(port: Int) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var opt: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let result = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if result != 0 {
        Darwin.close(fd)
        return nil
    }
    return fd
}

/// Probes for `count` contiguous ports this test process can bind right now, so fixture stores that
/// really bind their assigned ports (via `PortReservationReconciler`) can seed `appPortRangeStart`
/// with a range this machine has just proven free, instead of inheriting `PortRange.default`
/// (20000-30000) — the range real workspaces on this machine allocate from, and so may already hold.
///
/// Candidates start above `PortRange.default` and stay below the OS ephemeral range (49152+ on macOS)
/// that outgoing connections draw from, so a probe here neither collides with a real daemon's
/// reservations nor races the kernel handing the same port to an unrelated socket mid-probe.
func probeBindablePortRange(count: Int = 4) throws -> PortRange {
    var base = 31000
    while base + count < 49000 {
        var boundFDs: [Int32] = []
        defer { for fd in boundFDs { Darwin.close(fd) } }
        var allBound = true
        for offset in 0..<count {
            guard let fd = bindTestPlaceholderSocket(port: base + offset) else {
                allBound = false
                break
            }
            boundFDs.append(fd)
        }
        if allBound { return PortRange(start: base, end: base + count - 1) }
        base += 100
    }
    throw XCTSkip("No contiguous bindable port range found for test fixtures.")
}

/// Seeds `store`'s port-allocation range with a contiguous range this test process has just verified it
/// can bind, so a fixture workspace's assigned ports never land in `PortRange.default` (20000-30000) — the
/// range real workspaces on this machine assign from, and a real daemon may already hold ports there.
/// Must be called before any workspace's ports are assigned, since allocation reads the range at
/// assignment time.
func seedBindablePortRange(in store: SQLiteStore, count: Int = 4) throws {
    let range = try probeBindablePortRange(count: count)
    try store.setSetting(key: SettingsKey.appPortRangeStart, value: String(range.start))
    try store.setSetting(key: SettingsKey.appPortRangeEnd, value: String(range.end))
}

func makeProjectRecord(id: String = UUID().uuidString, dir: String) -> ProjectRecord {
    ProjectRecord(
        id: id, name: "Project", dir: dir, isGitRepo: false, defaultBranch: nil, setupScript: nil, stopScript: nil, ports: [], processes: [],
        browserSessions: [])
}

func makeWorkspaceRecord(id: String = UUID().uuidString, projectID: String, dir: String, branch: String? = nil) -> WorkspaceRecord {
    WorkspaceRecord(id: id, projectID: projectID, dir: dir, dirname: nil, branch: branch, isDefault: false, isRunning: false, lastLaunchedAt: nil)
}

/// Seeds the tracked terminal-session window that a live Spaces terminal session creates before any
/// agent hook fires. In the session-based model the agent correlates to this existing window (matched
/// by session id) instead of minting its own dedicated row, so the agent label is not auto-suffixed
/// against a window it just created for itself.
func seedTerminalSessionWindow(store: SQLiteStore, workspaceID: String, sessionID: String) throws {
    try store.upsert(
        window: WindowRecord(
            id: UUID().uuidString, workspaceID: workspaceID, app: TerminalHost.spaces.appName, name: sessionID, detail: nil, targetURL: nil,
            terminalTrackingID: sessionID, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
}

/// Writes the `terminal_sessions` row that has to exist before any runtime state is persisted for a
/// session.
///
/// Production establishes it inside the session host: `startIfNeeded` writes the launch configuration as
/// its first persistence action, before the host's first runtime-state write, and every other per-session
/// table is keyed off that row. The real `builtInTerminalWindowOpener` writes nothing durable at all — it
/// posts an IPC notification asking the app to open a pane — so a fixture that uses the opener as a
/// stand-in for a live session host must seed the row the host would have written.
func seedTerminalSessionRow(
    sessionID: String, paths: TerminalSessionPaths, workspaceID: String = "workspace-1", createdAt: String = "2026-05-09T17:00:00Z"
) throws {
    try TerminalSessionPersistence.writeLaunchConfiguration(
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, title: sessionID, workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, createdAt: createdAt,
            workspaceID: workspaceID, kind: .shell), paths: paths)
}

/// Marks a built-in terminal session as live for window-reconciliation purposes. Window liveness is
/// session-based: a control socket must be present, an active owner attachment must exist, and the
/// service PID must be alive. Tests that exercise `refreshWorkspaceWindows` must establish those session
/// artifacts for the window to survive reconciliation. The session's runtime state (with a live
/// `servicePID`) must already be written by the caller.
func markBuiltInSessionLive(sessionID: String, attachedAt: String = "2026-06-06T00:00:00Z") throws {
    let paths = try TerminalSessionPaths.forSession(id: sessionID)
    try paths.ensureDirectories()
    _ = FileManager.default.createFile(atPath: paths.controlSocketPath, contents: Data())
    let client = TerminalClient(
        id: "owner-\(sessionID)", kind: .localWindow, identity: .init(label: "Spaces window", hostName: "mac", deviceName: "Owner Mac"),
        connectedAt: attachedAt)
    let attachment = TerminalAttachment(sessionID: sessionID, clientID: client.id, mode: .owner, attachedAt: attachedAt)
    try TerminalSessionPersistence.writeAttachmentSnapshot(
        TerminalSessionAttachmentSnapshot(clients: [client], attachments: [attachment]), paths: paths)
}
