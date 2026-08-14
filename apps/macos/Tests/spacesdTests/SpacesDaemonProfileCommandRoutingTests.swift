import Foundation
import XCTest

#if os(macOS)
    @testable import spacesd
    @testable import spacesterminalcore

    /// Guards the daemon routing contract that keeps it deadlock-free (the terminal-engine-actor one-way
    /// rule). A profile command whose orchestrator call graph reaches the built-in terminal launcher or
    /// terminator enters the engine actor via `TerminalEngineActor.runSynchronously`, which traps when
    /// called from the main actor. `dispatch(_:)` must peel exactly those commands off the main actor;
    /// `SpacesDaemonProfileCommandRouting.requiresOffMainExecution` is the single source of truth for the
    /// classification, and `profileCommandOffMain` asserts against it, so a regression that routes an
    /// engine-touching command onto the main actor (as `.workspaceStart`/`.workspaceStop`/`.workspaceRestart`/`.agentKill`/
    /// `.agentSignal` previously were) would abort the daemon in the field. This locks the contract down.
    final class SpacesDaemonProfileCommandRoutingTests: XCTestCase {
        /// Every command that can reach the launcher (session create/send, workspace start/restart) or the
        /// terminator (workspace stop, agent kill's stop chokepoint, an agent-signal `exit`'s terminal teardown) must run
        /// off the main actor.
        func testEngineTouchingCommandsRequireOffMainExecution() {
            let offMain: [TerminalServiceProfileCommand] = [
                .terminalSend(TerminalServiceTerminalSendPayload(sessionID: "s", input: .text("hi"))),
                .terminalCommand(TerminalServiceTerminalCommandPayload(cwd: "/tmp")),
                .agentSpawn(TerminalServiceAgentSpawnPayload(cwd: "/tmp", command: "claude")), .workspaceStart(.init(cwd: "/tmp", workspaceID: "w")),
                .workspaceStop(workspaceID: "w"), .workspaceRestart(.init(cwd: "/tmp", workspaceID: "w")),
                .agentKill(TerminalServiceAgentKillPayload(sessionID: "s")),
                .agentSignal(TerminalServiceProfileAgentSignalPayload(workspaceID: "w", terminalSessionID: "s", event: "exit")),
            ]
            for command in offMain {
                XCTAssertTrue(
                    SpacesDaemonProfileCommandRouting.requiresOffMainExecution(command),
                    "engine-touching command \(command) must be peeled off the main actor")
            }
        }

        /// Every engine-free command (pure store/disk reads and metadata writes) keeps running its bulk on
        /// the main actor through the `profileCommandOffMain` bridge.
        func testEngineFreeCommandsRunOnMain() {
            let onMain: [TerminalServiceProfileCommand] = [
                .projectList, .terminalList, .terminalTail(TerminalServiceTerminalTailPayload(sessionID: "s")),
                .workspaceList(TerminalServiceWorkspaceListPayload()),
                .workspaceCreate(TerminalServiceWorkspaceCreatePayload(projectID: "p", branch: "b")), .agentList(TerminalServiceAgentListPayload()),
                .agentAnnotate(TerminalServiceAgentAnnotatePayload(sessionID: "s", note: "n")),
                .agentSubscribe(TerminalServiceAgentSubscriptionPayload(subscriberTerminalSessionID: "a", agentSessionID: "b")),
                .agentUnsubscribe(TerminalServiceAgentSubscriptionPayload(subscriberTerminalSessionID: "a", agentSessionID: "b")),
                .agentConsumePendingEvents(subscriberTerminalSessionID: "a"),
            ]
            for command in onMain {
                XCTAssertFalse(
                    SpacesDaemonProfileCommandRouting.requiresOffMainExecution(command),
                    "engine-free command \(command) must not be classified off-main")
            }
        }
    }
#endif
