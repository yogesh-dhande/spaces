import Foundation
import Testing
import spacesterminalcore

@testable import spacesdevicecore

@Suite struct LostShellResumeRequestsTests {
    /// Reference wrapper so `#expect` can call the mutating `claim`.
    private final class Asker {
        private var requests = LostShellResumeRequests()
        func claim(sessionID: String, overview: SpacesDeviceOverviewPayload?) -> Bool { requests.claim(sessionID: sessionID, overview: overview) }
        func release(sessionID: String) { requests.release(sessionID: sessionID) }
        func finish(sessionID: String) { requests.finish(sessionID: sessionID) }
        func holds(sessionID: String, overview: SpacesDeviceOverviewPayload?) -> Bool {
            requests.holdsFailedState(sessionID: sessionID, overview: overview)
        }
    }

    private struct Refusal: Error, SpacesDeviceErrorCodeProviding { let spacesDeviceErrorCode: SpacesDeviceErrorCode? }

    private func session(id: String, state: TerminalSessionState) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: "shell", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil, state: state, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 1, childPID: 2, workspaceID: "ws", workspaceTitle: "Workspace", projectID: "project",
            projectName: "Project", createdAt: "2026-10-15T09:00:00Z", updatedAt: "2026-10-15T09:00:00Z", isControlAvailable: true,
            isSubscriptionAvailable: true, attachmentSnapshot: .init())
    }

    private func overview(
        sessions: [SpacesDeviceTerminalSessionSummary], terminalSessionID: String? = nil, agentSessionID: String? = nil,
        processSessionID: String? = nil
    ) -> SpacesDeviceOverviewPayload {
        let terminals =
            terminalSessionID.map {
                [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-window:1", workspaceID: "ws", title: "shell-1", workingDirectory: "/tmp", sessionID: $0, runState: .exited,
                        canOpenTerminal: true)
                ]
            } ?? []
        let agents =
            agentSessionID.map {
                [
                    SpacesDeviceWorkspaceCodingAgentRow(
                        id: "agent:1", workspaceID: "ws", name: "claude", command: "claude", agentID: "a1", sessionID: $0, runState: .exited,
                        activityState: .exited, brief: nil, briefUpdatedAt: nil, canStop: false)
                ]
            } ?? []
        let processes =
            processSessionID.map {
                [
                    SpacesDeviceWorkspaceProcessRow(
                        id: "api", workspaceID: "ws", name: "api", command: "echo", processID: "p1", sessionID: $0, runState: .exited, canRun: true,
                        canStop: false, canRestart: true)
                ]
            } ?? []
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "ws", projectID: "project", projectName: "project", branch: nil, baseBranch: nil, dir: "/tmp", isRunning: true, isHidden: false,
            isDefault: false, hasTrackedRuntimeIndicators: false, processRows: processes, codingAgentRows: agents, terminalRows: terminals)
        return SpacesDeviceOverviewPayload(
            workspaces: [workspace], sessions: sessions,
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0))
    }

    @Test func aFailedSessionANamedByATerminalRowIsAskedAboutOnce() {
        let requests = Asker()
        let payload = overview(sessions: [session(id: "lost", state: .failed)], terminalSessionID: "lost")

        #expect(requests.claim(sessionID: "lost", overview: payload))
        #expect(!requests.claim(sessionID: "lost", overview: payload), "showing the pane again never asks again")
    }

    @Test func aShellTheUserEndedIsNeverAskedAbout() {
        let requests = Asker()
        let payload = overview(sessions: [session(id: "done", state: .exited)], terminalSessionID: "done")

        #expect(!requests.claim(sessionID: "done", overview: payload))
    }

    @Test func aFailedAgentOrProcessSessionIsNeverAskedAbout() {
        let requests = Asker()
        let payload = overview(
            sessions: [session(id: "agent", state: .failed), session(id: "proc", state: .failed)], agentSessionID: "agent", processSessionID: "proc")

        #expect(!requests.claim(sessionID: "agent", overview: payload))
        #expect(!requests.claim(sessionID: "proc", overview: payload))
    }

    @Test func aSessionNoTerminalRowNamesIsNeverAskedAbout() {
        let requests = Asker()

        #expect(!requests.claim(sessionID: "orphan", overview: overview(sessions: [session(id: "orphan", state: .failed)])))
    }

    /// A pane shown before the device's overview has loaded cannot be judged yet; it must stay eligible so
    /// the next show asks once the overview names the session.
    @Test func aSessionNotYetInTheOverviewStaysEligible() {
        let requests = Asker()

        #expect(!requests.claim(sessionID: "lost", overview: nil))
        #expect(requests.claim(sessionID: "lost", overview: overview(sessions: [session(id: "lost", state: .failed)], terminalSessionID: "lost")))
    }

    /// After a reboot the panes are restored before the device reports anything: first no overview, then an
    /// overview that does not list the session yet, then the one that does. Each overview install
    /// re-evaluates the visible pane, and only the one that lists the lost shell sends, once.
    @Test func aPaneShownBeforeTheOverviewListsItsSessionAsksOnceTheOverviewArrives() {
        let requests = Asker()
        let lost = overview(sessions: [session(id: "lost", state: .failed)], terminalSessionID: "lost")

        let beforeAnyOverview = requests.claim(sessionID: "lost", overview: nil)
        let beforeItIsListed = requests.claim(sessionID: "lost", overview: overview(sessions: []))
        let whenListed = requests.claim(sessionID: "lost", overview: lost)
        let onTheNextInstall = requests.claim(sessionID: "lost", overview: lost)

        #expect(!beforeAnyOverview)
        #expect(!beforeItIsListed)
        #expect(whenListed)
        #expect(!onTheNextInstall)
    }

    /// A shell held by a pending restore offer is refused with `.restorePending`; the session is released so
    /// the overview install that follows the offer being answered asks again. Any other refusal is final.
    @Test func aRestorePendingRefusalReleasesTheSessionAndOtherRefusalsDoNot() {
        let requests = Asker()
        let lost = overview(sessions: [session(id: "lost", state: .failed)], terminalSessionID: "lost")
        let first = requests.claim(sessionID: "lost", overview: lost)
        #expect(first)
        #expect(LostShellResumeRequests.isRestorePending(Refusal(spacesDeviceErrorCode: .restorePending)))
        #expect(!LostShellResumeRequests.isRestorePending(Refusal(spacesDeviceErrorCode: .conflict)))

        requests.release(sessionID: "lost")
        let afterSkip = requests.claim(sessionID: "lost", overview: lost)
        let again = requests.claim(sessionID: "lost", overview: lost)

        #expect(afterSkip)
        #expect(!again)
    }

    @Test func onlyAMissingFolderRefusalIsReportedOnThePane() {
        #expect(LostShellResumeRequests.isFolderMissing(Refusal(spacesDeviceErrorCode: .workingDirectoryMissing)))
        #expect(!LostShellResumeRequests.isFolderMissing(Refusal(spacesDeviceErrorCode: .conflict)))
        #expect(!LostShellResumeRequests.isFolderMissing(Refusal(spacesDeviceErrorCode: nil)))
    }

    // MARK: - Holding the failed state while a request is pending

    private var lostOverview: SpacesDeviceOverviewPayload { overview(sessions: [session(id: "lost", state: .failed)], terminalSessionID: "lost") }

    @Test func aFailedTerminalRowSessionIsHeldFromTheMomentItWouldAskUntilTheAnswer() {
        let requests = Asker()

        #expect(requests.holds(sessionID: "lost", overview: lostOverview), "would ask: held before the claim")
        #expect(requests.claim(sessionID: "lost", overview: lostOverview))
        #expect(requests.holds(sessionID: "lost", overview: lostOverview), "in flight: held")
        requests.finish(sessionID: "lost")
        #expect(!requests.holds(sessionID: "lost", overview: lostOverview), "answered: the outcome shows")
    }

    /// The session stream can report the failure before the overview that lists it, or before any
    /// overview exists.
    @Test func aFailureReportedBeforeTheOverviewListsItIsHeld() {
        let requests = Asker()

        #expect(requests.holds(sessionID: "lost", overview: nil))
        #expect(requests.holds(sessionID: "lost", overview: overview(sessions: [session(id: "lost", state: .running)], terminalSessionID: "lost")))
        #expect(requests.holds(sessionID: "lost", overview: overview(sessions: [], terminalSessionID: "lost")))
    }

    @Test func aSessionThatWillNeverBeAskedIsNeverHeld() {
        let requests = Asker()
        let agentAndProcess = overview(
            sessions: [session(id: "agent", state: .failed), session(id: "proc", state: .failed)], agentSessionID: "agent", processSessionID: "proc")

        #expect(!requests.holds(sessionID: "agent", overview: agentAndProcess))
        #expect(!requests.holds(sessionID: "proc", overview: agentAndProcess))
        #expect(!requests.holds(sessionID: "done", overview: overview(sessions: [session(id: "done", state: .exited)], terminalSessionID: "done")))
        #expect(!requests.holds(sessionID: "orphan", overview: overview(sessions: [session(id: "orphan", state: .failed)])))
    }

    /// A shell held by a pending restore offer shows its failed state rather than waiting indefinitely; the
    /// release that follows the refusal ends the hold, and a later claim (the offer was answered) holds again.
    @Test func aRestorePendingRefusalEndsTheHoldUntilTheShellIsAskedAgain() {
        let requests = Asker()
        #expect(requests.claim(sessionID: "lost", overview: lostOverview))

        requests.release(sessionID: "lost")
        #expect(!requests.holds(sessionID: "lost", overview: lostOverview))

        #expect(requests.claim(sessionID: "lost", overview: lostOverview))
        #expect(requests.holds(sessionID: "lost", overview: lostOverview))
    }
}
