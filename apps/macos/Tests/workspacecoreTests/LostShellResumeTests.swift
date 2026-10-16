import XCTest
import spacestestsupport
import systembridge

@testable import spacesterminalcore
@testable import workspacecore

/// A launch seen by the stand-in for the daemon's session launcher: the configuration, and the bytes the
/// new session's `output.log` already held when the launch happened, which is what the real core replays.
private final class SeededLaunchCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var launches: [(configuration: TerminalSessionLaunchConfiguration, seed: Data, grid: (columns: Int, rows: Int)?)] = []

    func record(_ configuration: TerminalSessionLaunchConfiguration) {
        let paths = try? TerminalSessionPaths.forSession(id: configuration.sessionID)
        let seed = paths.flatMap { FileManager.default.contents(atPath: $0.outputPath) } ?? Data()
        lock.lock()
        launches.append((configuration, seed, paths?.seedTranscriptGrid()))
        lock.unlock()
    }

    var all: [(configuration: TerminalSessionLaunchConfiguration, seed: Data, grid: (columns: Int, rows: Int)?)] {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }
}

final class LostShellResumeTests: XCTestCase {
    override func setUpWithError() throws { try useIsolatedSpacesProfile() }

    private let oldTranscript = Data("echo hi\r\nhi\r\n$ ".utf8)

    private final class Fixture {
        let store: SQLiteStore
        let orchestrator: WorkspaceOrchestrator
        let workspace: WorkspaceRecord
        let projectDirectory: URL
        let launchFailure: LaunchFailureSwitch

        init(
            store: SQLiteStore, orchestrator: WorkspaceOrchestrator, workspace: WorkspaceRecord, projectDirectory: URL,
            launchFailure: LaunchFailureSwitch
        ) {
            self.store = store
            self.orchestrator = orchestrator
            self.workspace = workspace
            self.projectDirectory = projectDirectory
            self.launchFailure = launchFailure
        }
    }

    /// `persistLaunches` writes each launch configuration to the session store the way the real launcher
    /// does, for tests that read a replacement's stored title back.
    private func makeFixture(launchDelay: TimeInterval = 0, persistLaunches: Bool = false) throws -> (Fixture, SeededLaunchCapture) {
        let root = try makeTempDirectory()
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let launches = SeededLaunchCapture()
        let launchFailure = LaunchFailureSwitch()
        let orchestrator = makeTestOrchestrator(
            store: store,
            builtInTerminalSessionLauncher: { configuration in
                if launchFailure.isOn { throw WorkspaceError.invalidArgument(message: "launcher failed") }
                launches.record(configuration)
                if persistLaunches {
                    let paths = try TerminalSessionPaths.forSession(id: configuration.sessionID)
                    try paths.ensureDirectories()
                    try TerminalSessionPersistence.writeLaunchConfiguration(configuration, paths: paths)
                }
                if launchDelay > 0 { Thread.sleep(forTimeInterval: launchDelay) }
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                    launchConfiguration: configuration)
            })
        let project = try orchestrator.addProject(dir: projectDirectory.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)
        try FileManager.default.createDirectory(atPath: workspace.dir, withIntermediateDirectories: true)
        return (
            Fixture(store: store, orchestrator: orchestrator, workspace: workspace, projectDirectory: projectDirectory, launchFailure: launchFailure),
            launches
        )
    }

    /// Writes what a shell lost to a reboot leaves behind: its launch configuration, a runtime row stale
    /// recovery marked `.failed`, its transcript, and the terminal row naming it.
    @discardableResult private func makeLostShell(
        _ fixture: Fixture, state: TerminalSessionState = .failed, kind: TerminalSessionKind = .shell, workingDirectory: String? = nil,
        windowName: String = "shell-1", launchTitle: String? = nil, userTitle: String? = nil
    ) throws -> String {
        let sessionID = UUID().uuidString
        let directory = workingDirectory ?? fixture.workspace.dir
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        try paths.ensureDirectories()
        try TerminalSessionPersistence.writeLaunchConfiguration(
            TerminalSessionLaunchConfiguration(
                sessionID: sessionID, title: launchTitle ?? windowName, workingDirectory: directory, shell: "/bin/zsh", command: "exec zsh",
                createdAt: "2026-10-15T20:00:00.000Z", workspaceID: fixture.workspace.id, kind: kind), paths: paths)
        if let userTitle { try TerminalSessionPersistence.writeUserTitle(userTitle, sessionID: sessionID, paths: paths) }
        try TerminalSessionPersistence.writeRuntimeState(
            .init(
                sessionID: sessionID, servicePID: 100, childPID: 200, state: state, updatedAt: "2026-10-15T21:24:00Z",
                exitedAt: "2026-10-15T21:30:00Z", workingDirectory: directory, columns: 100, rows: 30), paths: paths)
        try oldTranscript.write(to: URL(fileURLWithPath: paths.outputPath))
        try fixture.store.upsert(
            window: WindowRecord(
                id: "window-\(sessionID)", workspaceID: fixture.workspace.id, app: TerminalHost.spaces.appName, name: windowName, detail: nil,
                targetURL: nil, terminalTrackingID: sessionID, role: "terminal", orderIndex: 207, lastSeenAt: "2026-10-15T20:00:00Z"))
        return sessionID
    }

    private func terminalRow(_ fixture: Fixture, named id: String) throws -> WindowRecord {
        try XCTUnwrap(fixture.store.windows(workspaceID: fixture.workspace.id).first { $0.id == id })
    }

    private func assertNotResumable(_ body: @autoclosure () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case WorkspaceError.sessionNotResumable = error else { return XCTFail("Unexpected error: \(error)", file: file, line: line) }
        }
    }

    func testLostShellIsReplacedByAFreshShellInTheSameRowWithTheSameDirectoryAndTitle() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)
        let rowID = "window-\(lostID)"

        let resumption = try fixture.orchestrator.resumeLostShell(sessionID: lostID)

        XCTAssertEqual(resumption.replacedSessionID, lostID)
        XCTAssertEqual(resumption.workspaceID, fixture.workspace.id)
        XCTAssertNotEqual(resumption.sessionID, lostID, "the replacement must be a new session, never the old id")
        let launch = try XCTUnwrap(launches.all.first)
        XCTAssertEqual(launches.all.count, 1)
        XCTAssertEqual(launch.configuration.sessionID, resumption.sessionID)
        XCTAssertEqual(launch.configuration.kind, .shell)
        XCTAssertEqual(launch.configuration.workingDirectory, fixture.workspace.dir)
        XCTAssertEqual(launch.configuration.title, "shell-1")
        XCTAssertEqual(launch.configuration.workspaceID, fixture.workspace.id)
        XCTAssertTrue(launch.configuration.command?.contains(resumption.sessionID) == true, "the shell's environment names the new session")
        let row = try terminalRow(fixture, named: rowID)
        XCTAssertEqual(row.terminalTrackingID, resumption.sessionID)
        XCTAssertEqual(row.name, "shell-1")
        XCTAssertEqual(row.orderIndex, 207)
        XCTAssertEqual(try fixture.store.windows(workspaceID: fixture.workspace.id).count, 1)
    }

    /// A rename lives apart from the generated launch name: the replacement keeps the rename as its user
    /// title and `shell-1` as its launch title, so clearing the rename brings `shell-1` back and the name
    /// is never released for another terminal to take.
    func testRenamedLostShellResumesWithTheRenameIntactAndClearingItShowsTheGeneratedName() throws {
        let (fixture, launches) = try makeFixture(persistLaunches: true)
        let lostID = try makeLostShell(fixture, windowName: "review", launchTitle: "shell-1", userTitle: "review")

        let resumption = try fixture.orchestrator.resumeLostShell(sessionID: lostID)

        // The rename travels in the launch configuration, so it lands in the same write as the session
        // itself rather than in a later one that can run before the write-behind insert commits.
        XCTAssertEqual(try XCTUnwrap(launches.all.first).configuration.title, "shell-1")
        XCTAssertEqual(try XCTUnwrap(launches.all.first).configuration.userTitle, "review")
        let replacementPaths = try TerminalSessionPaths.forSession(id: resumption.sessionID)
        let stored = try TerminalSessionPersistence.readLaunchConfiguration(paths: replacementPaths)
        XCTAssertEqual(stored.title, "shell-1")
        XCTAssertEqual(stored.userTitle, "review")
        XCTAssertEqual(try terminalRow(fixture, named: "window-\(lostID)").name, "review")

        XCTAssertTrue(
            try fixture.orchestrator.renameAdHocBuiltInTerminalSession(workspaceID: fixture.workspace.id, sessionID: resumption.sessionID, title: ""))

        XCTAssertEqual(try terminalRow(fixture, named: "window-\(lostID)").name, "shell-1")
    }

    func testReplacementTranscriptStartsWithTheOldBytesThenTheSeparatorBeforeTheShellLaunches() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)

        _ = try fixture.orchestrator.resumeLostShell(sessionID: lostID)

        let launch = try XCTUnwrap(launches.all.first)
        let seed = launch.seed
        XCTAssertEqual(launch.grid?.columns, 100, "the seed replays at the lost shell's grid")
        XCTAssertEqual(launch.grid?.rows, 30)
        XCTAssertTrue(seed.starts(with: oldTranscript))
        let tail = String(decoding: seed.dropFirst(oldTranscript.count), as: UTF8.self)
        XCTAssertTrue(tail.hasPrefix(String(decoding: TerminalLostShellSeed.modeReset(after: oldTranscript), as: UTF8.self)))
        XCTAssertTrue(tail.contains("Shell ended when "))
        XCTAssertTrue(tail.hasSuffix(" \u{00B7} new shell below\u{1B}[0m\r\n"))
    }

    func testRepeatRequestReturnsTheSameReplacementWithoutLaunchingAgain() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)

        let first = try fixture.orchestrator.resumeLostShell(sessionID: lostID)
        let second = try fixture.orchestrator.resumeLostShell(sessionID: lostID)

        XCTAssertEqual(second, first)
        XCTAssertEqual(launches.all.count, 1)
    }

    func testConcurrentRequestsLaunchOneShell() throws {
        let (fixture, launches) = try makeFixture(launchDelay: 0.3)
        let lostID = try makeLostShell(fixture)
        let secondConnection = try makeSecondTestStoreConnection()
        let secondOrchestrator = makeTestOrchestrator(
            store: secondConnection,
            builtInTerminalSessionLauncher: { configuration in
                launches.record(configuration)
                Thread.sleep(forTimeInterval: 0.3)
                return TerminalServiceSessionSummary(
                    id: configuration.sessionID, title: configuration.title, workingDirectory: configuration.workingDirectory,
                    backend: configuration.backend, lifetimePolicy: configuration.lifetimePolicy, state: .running, servicePID: 123, childPID: 456,
                    controlSocketPath: "/tmp/control-\(configuration.sessionID)", outputPath: "/tmp/output-\(configuration.sessionID)",
                    launchConfiguration: configuration)
            })
        let results = ResumptionResults()

        let group = DispatchGroup()
        for orchestrator in [fixture.orchestrator, secondOrchestrator] {
            group.enter()
            DispatchQueue.global().async {
                results.append(Result { try orchestrator.resumeLostShell(sessionID: lostID) })
                group.leave()
            }
        }
        group.wait()

        let sessionIDs = try results.all.map { try $0.get().sessionID }
        XCTAssertEqual(sessionIDs.count, 2)
        XCTAssertEqual(Set(sessionIDs).count, 1, "both callers must get the one replacement")
        XCTAssertEqual(launches.all.count, 1)
    }

    func testShellTheUserEndedIsRefused() throws {
        let (fixture, launches) = try makeFixture()
        let exitedID = try makeLostShell(fixture, state: .exited)

        assertNotResumable(try fixture.orchestrator.resumeLostShell(sessionID: exitedID))

        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertEqual(try terminalRow(fixture, named: "window-\(exitedID)").terminalTrackingID, exitedID)
    }

    func testLiveShellIsRefused() throws {
        let (fixture, launches) = try makeFixture()
        let runningID = try makeLostShell(fixture, state: .running)

        assertNotResumable(try fixture.orchestrator.resumeLostShell(sessionID: runningID))

        XCTAssertTrue(launches.all.isEmpty)
    }

    func testSessionOwnedByAProcessOrAgentIsRefused() throws {
        let (fixture, launches) = try makeFixture()
        let processID = try makeLostShell(fixture, kind: .process)
        let agentID = try makeLostShell(fixture, kind: .agent)

        assertNotResumable(try fixture.orchestrator.resumeLostShell(sessionID: processID))
        assertNotResumable(try fixture.orchestrator.resumeLostShell(sessionID: agentID))

        XCTAssertTrue(launches.all.isEmpty)
    }

    func testUnknownSessionIsRefused() throws {
        let (fixture, launches) = try makeFixture()

        assertNotResumable(try fixture.orchestrator.resumeLostShell(sessionID: UUID().uuidString))

        XCTAssertTrue(launches.all.isEmpty)
    }

    func testShellWhoseRowIsGoneIsRefused() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)
        try fixture.store.deleteWindow(id: "window-\(lostID)")

        assertNotResumable(try fixture.orchestrator.resumeLostShell(sessionID: lostID))

        XCTAssertTrue(launches.all.isEmpty)
    }

    func testSessionHeldByAPendingRestoreOfferIsRefusedUntilTheOfferIsAnswered() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)
        let capture = RestorableSessionCapture(
            sessionID: lostID, workspaceID: fixture.workspace.id, agentKind: nil, agentSessionKey: nil, launchCommand: "claude",
            workingDirectory: fixture.workspace.dir, title: "claude")
        try fixture.store.replaceRestorableSessions(generation: "generation-1", capturedAt: "2026-10-15T21:30:00Z", captures: [capture])

        XCTAssertThrowsError(try fixture.orchestrator.resumeLostShell(sessionID: lostID)) { error in
            guard case WorkspaceError.restorePending = error else { return XCTFail("Expected restorePending, got \(error)") }
        }
        XCTAssertTrue(launches.all.isEmpty)

        // Skip clears the record; the shell that hosted the agent is then an ordinary lost shell.
        try fixture.store.clearRestorableSessions(generation: "generation-1")
        let resumption = try fixture.orchestrator.resumeLostShell(sessionID: lostID)

        XCTAssertEqual(launches.all.count, 1)
        XCTAssertEqual(try terminalRow(fixture, named: "window-\(lostID)").terminalTrackingID, resumption.sessionID)
    }

    func testMissingWorkingDirectoryFailsDistinctlyAndLaunchesNothing() throws {
        let (fixture, launches) = try makeFixture()
        let gone = fixture.projectDirectory.appendingPathComponent("deleted-subfolder").path
        let lostID = try makeLostShell(fixture, workingDirectory: gone)

        XCTAssertThrowsError(try fixture.orchestrator.resumeLostShell(sessionID: lostID)) { error in
            guard case WorkspaceError.workingDirectoryMissing(let path) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(path, gone)
        }

        XCTAssertTrue(launches.all.isEmpty)
        XCTAssertEqual(try terminalRow(fixture, named: "window-\(lostID)").terminalTrackingID, lostID)
    }

    func testStoppedWorkspaceStillGetsItsShellAndReadsRunningAfterwards() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)
        XCTAssertFalse(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)

        _ = try fixture.orchestrator.resumeLostShell(sessionID: lostID)

        XCTAssertEqual(launches.all.count, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.store.workspace(id: fixture.workspace.id)).isRunning)
    }

    func testFailedLaunchLeavesTheRowOnTheLostShellSoARetryCanSucceed() throws {
        let (fixture, launches) = try makeFixture()
        let lostID = try makeLostShell(fixture)
        fixture.launchFailure.isOn = true

        XCTAssertThrowsError(try fixture.orchestrator.resumeLostShell(sessionID: lostID))

        XCTAssertEqual(try terminalRow(fixture, named: "window-\(lostID)").terminalTrackingID, lostID)
        XCTAssertTrue(launches.all.isEmpty)

        fixture.launchFailure.isOn = false
        let resumption = try fixture.orchestrator.resumeLostShell(sessionID: lostID)
        XCTAssertEqual(launches.all.count, 1)
        XCTAssertEqual(try terminalRow(fixture, named: "window-\(lostID)").terminalTrackingID, resumption.sessionID)
    }
}

private final class LaunchFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isOn: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class ResumptionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<LostShellResumption, Error>] = []

    func append(_ result: Result<LostShellResumption, Error>) {
        lock.lock()
        results.append(result)
        lock.unlock()
    }

    var all: [Result<LostShellResumption, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return results
    }
}
