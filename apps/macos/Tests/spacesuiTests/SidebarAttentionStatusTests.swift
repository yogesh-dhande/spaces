import Testing
import spacesdevicecore

@testable import spacesui

struct SidebarAttentionStatusTests {
    @Test func agentActivityMapsToItsSemanticColorStatus() {
        #expect(SidebarAttentionStatus.resolve(kind: .agent, runState: .running, agentActivityState: .spinning) == .working)
        #expect(SidebarAttentionStatus.resolve(kind: .agent, runState: .running, agentActivityState: .waiting) == .blocked)
        #expect(SidebarAttentionStatus.resolve(kind: .agent, runState: .running, agentActivityState: .done) == .done)
        #expect(SidebarAttentionStatus.resolve(kind: .agent, runState: .running, agentActivityState: .idle) == .inactive)
        #expect(SidebarAttentionStatus.resolve(kind: .agent, runState: .exited, agentActivityState: .exited) == .inactive)
    }

    @Test func processRunStateMapsToRunningExitedAndInactive() {
        #expect(SidebarAttentionStatus.resolve(kind: .process, runState: .running, agentActivityState: nil) == .working)
        #expect(SidebarAttentionStatus.resolve(kind: .process, runState: .exited, agentActivityState: nil) == .failed)
        #expect(SidebarAttentionStatus.resolve(kind: .missingConfiguredProcess, runState: .notStarted, agentActivityState: nil) == .inactive)
    }

    /// Dismissing an exited process's alert is the one dismissal that changes a row's color: it drops
    /// straight to inactive (the unstarted-process color, hollow like failed) rather than to some
    /// intermediate "acknowledged failure" shade.
    @Test func acknowledgedProcessExitDowngradesToInactive() {
        #expect(SidebarAttentionStatus.resolve(kind: .process, runState: .exited, agentActivityState: nil, isExitAcknowledged: true) == .inactive)
        #expect(SidebarAttentionStatus.resolve(kind: .process, runState: .exited, agentActivityState: nil, isExitAcknowledged: false) == .failed)
        // Acknowledgment is meaningless off the exited state: a running process ignores the flag.
        #expect(SidebarAttentionStatus.resolve(kind: .process, runState: .running, agentActivityState: nil, isExitAcknowledged: true) == .working)
    }

    @Test func terminalAndBrowserRowsDoNotParticipateInOperationalStatusColors() {
        #expect(SidebarAttentionStatus.resolve(kind: .window, runState: .running, agentActivityState: nil) == nil)
        #expect(SidebarAttentionStatus.resolve(kind: .window, runState: .exited, agentActivityState: nil) == nil)
        #expect(SidebarAttentionStatus.resolve(kind: .browser, runState: nil, agentActivityState: nil) == nil)
    }

    @Test func workspacePriorityIsFailureThenBlockedThenDoneThenWorkingThenInactive() {
        #expect(SidebarAttentionStatus.highest([.inactive, .working]) == .working)
        #expect(SidebarAttentionStatus.highest([.working, .done]) == .done)
        #expect(SidebarAttentionStatus.highest([.done, .blocked]) == .blocked)
        #expect(SidebarAttentionStatus.highest([.blocked, .failed]) == .failed)
        #expect(SidebarAttentionStatus.highest([]) == .inactive)
    }

    @Test func failedAndInactiveWorkspaceAttentionUseHollowDots() {
        #expect(!SidebarAttentionStatus.failed.usesFilledIndicator)
        #expect(!SidebarAttentionStatus.inactive.usesFilledIndicator)
        #expect(SidebarAttentionStatus.blocked.usesFilledIndicator)
        #expect(SidebarAttentionStatus.done.usesFilledIndicator)
        #expect(SidebarAttentionStatus.working.usesFilledIndicator)
    }
}
