import Foundation
import XCTest

#if os(macOS)
    @testable import spacesd
    @testable import spacesterminalcore

    /// The daemon's gate for requests whose terminal came from the caller's environment. The "shell" of
    /// the terminal is this test process, so a child of it is inside the terminal and the test process's own
    /// parent (the test runner) is outside it.
    final class SpacesDaemonCallerAttributionTests: XCTestCase {
        private let terminal = CallerTerminalCheck { sessionID in
            ["terminal-1", "child-terminal", "unrelated-terminal"].contains(sessionID) ? getpid() : nil
        }
        private let outside = getppid()
        private var inside: Int32 = 0
        private var child: Process?

        override func setUpWithError() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            child = process
            inside = process.processIdentifier
        }

        override func tearDown() {
            child?.terminate()
            child?.waitUntilExit()
        }

        /// run-1 started in terminal-1; the terminal it spawned, child-terminal, carries the run's stamp.
        private func early(_ command: TerminalServiceProfileCommand) -> TerminalServiceResponse? {
            SpacesDaemonCallerAttribution.earlyResponse(
                for: command, check: terminal,
                terminalBelongsToAutomationRun: { terminalID, runID in runID == "run-1" && ["terminal-1", "child-terminal"].contains(terminalID) })
        }

        func testSignalFromInsideTheTerminalIsRecorded() {
            let signal = TerminalServiceProfileAgentSignalPayload(
                workspaceID: "w", terminalSessionID: "terminal-1", event: "working", callerProcessID: inside)
            XCTAssertNil(early(.agentSignal(signal)))
        }

        func testSignalFromOutsideTheTerminalIsDroppedWithAnOkReply() throws {
            let signal = TerminalServiceProfileAgentSignalPayload(
                workspaceID: "w", terminalSessionID: "terminal-1", event: "working", callerProcessID: outside)
            let response = try XCTUnwrap(early(.agentSignal(signal)))
            XCTAssertTrue(response.ok)
            XCTAssertNil(response.agentSignals)
            XCTAssertNotNil(response.profile)
            try assertClientAcceptsAsProfileReply(response)
        }

        func testSignalWithAnExplicitTerminalCarriesNoPidAndIsRecorded() {
            XCTAssertNil(early(.agentSignal(.init(workspaceID: "w", terminalSessionID: "terminal-1", event: "working"))))
        }

        func testBriefWriteFromOutsideIsRefusedAndFromInsideOrExplicitRuns() throws {
            let refused = try XCTUnwrap(early(.agentBriefWrite(.init(sessionID: "terminal-1", markdown: "m", callerProcessID: outside))))
            XCTAssertFalse(refused.ok)
            XCTAssertTrue(refused.message.contains("not running inside the Spaces terminal"))
            XCTAssertNil(early(.agentBriefWrite(.init(sessionID: "terminal-1", markdown: "m", callerProcessID: inside))))
            XCTAssertNil(early(.agentBriefWrite(.init(sessionID: "terminal-1", markdown: "m"))))
        }

        func testEveryEnvironmentDefaultedCommandIsRefusedFromOutside() {
            let commands: [TerminalServiceProfileCommand] = [
                .agentList(.init(sessionID: "terminal-1", callerProcessID: outside)),
                .agentBriefRead(.init(sessionID: "terminal-1", callerProcessID: outside)),
                .agentBriefClear(.init(sessionID: "terminal-1", callerProcessID: outside)),
                .agentSubscribe(.init(subscriberTerminalSessionID: "terminal-1", agentSessionID: "a", callerProcessID: outside)),
                .agentUnsubscribe(.init(subscriberTerminalSessionID: "terminal-1", agentSessionID: "a", callerProcessID: outside)),
                .agentSpawn(.init(cwd: "/tmp", command: "claude", callerProcessID: outside, callerTerminalSessionID: "terminal-1")),
            ]
            for command in commands { XCTAssertEqual(early(command)?.ok, false, "\(command)") }
        }

        func testPendingEventDrainFromOutsideConsumesNothingAndSucceeds() throws {
            let response = try XCTUnwrap(early(.agentConsumePendingEvents(.init(sessionID: "terminal-1", callerProcessID: outside))))
            XCTAssertTrue(response.ok)
            XCTAssertNotNil(response.profile)
            XCTAssertNil(response.profile?.pendingAgentEvents)
            try assertClientAcceptsAsProfileReply(response)
            XCTAssertNil(early(.agentConsumePendingEvents(.init(sessionID: "terminal-1", callerProcessID: inside))))
        }

        /// The wire round-trip a client applies before `sendProfileCommand` checks `profile`, so an ok reply
        /// without one (which that call turns into an error) is caught without a socket.
        private func assertClientAcceptsAsProfileReply(_ response: TerminalServiceResponse) throws {
            let decoded = try JSONDecoder().decode(TerminalServiceResponse.self, from: JSONEncoder().encode(response))
            XCTAssertTrue(decoded.ok)
            XCTAssertNotNil(decoded.profile)
        }

        private func spawn(terminal: String?, pid: Int32, run: String? = "run-1") -> TerminalServiceProfileCommand {
            .agentSpawn(.init(cwd: "/tmp", command: "claude", automationRunID: run, callerProcessID: pid, callerTerminalSessionID: terminal))
        }

        func testSpawnFromTheRunsOriginalTerminalIsAllowed() { XCTAssertNil(early(spawn(terminal: "terminal-1", pid: inside))) }

        func testNestedSpawnFromATerminalStampedWithTheRunIsAllowed() { XCTAssertNil(early(spawn(terminal: "child-terminal", pid: inside))) }

        func testSpawnFromAnUnrelatedTerminalClaimingTheRunIsRefused() {
            XCTAssertEqual(early(spawn(terminal: "unrelated-terminal", pid: inside))?.ok, false)
        }

        func testSpawnFromOutsideTheNamedTerminalIsRefused() { XCTAssertEqual(early(spawn(terminal: "child-terminal", pid: outside))?.ok, false) }

        func testSpawnClaimingARunWithNoCallerTerminalIsRefused() { XCTAssertEqual(early(spawn(terminal: nil, pid: inside))?.ok, false) }

        func testSpawnWithoutARunIdOrCallerKeepsTodaysBehavior() { XCTAssertNil(early(spawn(terminal: nil, pid: inside, run: nil))) }

        func testUnknownTerminalKeepsTodaysBehavior() {
            XCTAssertNil(early(.agentBriefWrite(.init(sessionID: "ended-terminal", markdown: "m", callerProcessID: outside))))
        }
    }
#endif
