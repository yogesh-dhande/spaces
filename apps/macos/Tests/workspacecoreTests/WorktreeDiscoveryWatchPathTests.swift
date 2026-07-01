import Testing

@testable import workspacecore

@Suite struct WorktreeDiscoveryWatchPathTests {
    private let commonDir = "/repo/.git"

    @Test func sharedHeadChangeIsRelevant() {
        #expect(WorktreeDiscoveryService.changedPathsAffectWorktrees(["/repo/.git/HEAD"], commonDirectory: commonDir))
    }

    @Test func linkedWorktreeChangesAreRelevant() {
        #expect(WorktreeDiscoveryService.changedPathsAffectWorktrees(["/repo/.git/worktrees"], commonDirectory: commonDir))
        #expect(WorktreeDiscoveryService.changedPathsAffectWorktrees(["/repo/.git/worktrees/feature/HEAD"], commonDirectory: commonDir))
    }

    @Test func commitChurnIsIgnored() {
        let churn = ["/repo/.git/logs/HEAD", "/repo/.git/objects/ab/cdef", "/repo/.git/index", "/repo/.git/refs/heads/main"]
        #expect(!WorktreeDiscoveryService.changedPathsAffectWorktrees(churn, commonDirectory: commonDir))
    }
}
