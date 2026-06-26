import Testing

@testable import spacesui

@Suite struct WorktreeDiscoveryWatchPathTests {
    private let commonDir = "/repo/.git"

    @Test func sharedHeadChangeIsRelevant() {
        #expect(AppKitController.changedPathsAffectWorktrees(["/repo/.git/HEAD"], commonDirectory: commonDir))
    }

    @Test func linkedWorktreeChangesAreRelevant() {
        #expect(AppKitController.changedPathsAffectWorktrees(["/repo/.git/worktrees"], commonDirectory: commonDir))
        #expect(AppKitController.changedPathsAffectWorktrees(["/repo/.git/worktrees/feature/HEAD"], commonDirectory: commonDir))
    }

    @Test func commitChurnIsIgnored() {
        let churn = ["/repo/.git/logs/HEAD", "/repo/.git/objects/ab/cdef", "/repo/.git/index", "/repo/.git/refs/heads/main"]
        #expect(!AppKitController.changedPathsAffectWorktrees(churn, commonDirectory: commonDir))
    }
}
