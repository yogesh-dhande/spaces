import Testing

@testable import spacesdeviceapi

@Suite struct SpacesDeviceWorkspaceWatchEventAcceptanceTests {
    private typealias Repository = WorkspaceWatchEventAcceptance.Repository

    private let root = Repository(workingDir: "/ws", gitDir: "/ws/.git", commonDir: "/ws/.git", ancestorWorkingDirs: [])
    private let submoduleA = Repository(
        workingDir: "/ws/A", gitDir: "/ws/.git/modules/A", commonDir: "/ws/.git/modules/A", ancestorWorkingDirs: ["/ws"])
    private let submoduleB = Repository(
        workingDir: "/ws/A/B", gitDir: "/ws/.git/modules/A/modules/B", commonDir: "/ws/.git/modules/A/modules/B",
        ancestorWorkingDirs: ["/ws/A", "/ws"])

    private func touched(_ path: String, ignored: [String: Set<String>] = [:]) -> Set<String>? {
        WorkspaceWatchEventAcceptance.touchedWorkingDirectories(
            forChangedPath: path, repositories: [root, submoduleA, submoduleB], ignoredDirectories: { ignored[$0] ?? [] })
    }

    @Test func eventUnderNestedSubmoduleTouchesItAndItsAncestorsOnly() {
        #expect(touched("/ws/A/B/deep.txt") == ["/ws/A/B", "/ws/A", "/ws"])
    }

    @Test func eventAtRootOnlyTouchesRoot() {
        #expect(touched("/ws/README.md") == ["/ws"])
    }

    @Test func objectsAndLockFilesUnderAGitDirAreDropped() {
        #expect(touched("/ws/.git/objects/ab/cdef") == nil)
        #expect(touched("/ws/.git/index.lock") == nil)
        #expect(touched("/ws/.git/logs/HEAD") == nil)
    }

    @Test func headIndexPackedRefsAndRefsHeadsTouchTheOwningRepository() {
        #expect(touched("/ws/.git/HEAD") == ["/ws"])
        #expect(touched("/ws/.git/index") == ["/ws"])
        #expect(touched("/ws/.git/packed-refs") == ["/ws"])
        #expect(touched("/ws/.git/MERGE_HEAD") == ["/ws"])
        #expect(touched("/ws/.git/REBASE_HEAD") == ["/ws"])
        #expect(touched("/ws/.git/CHERRY_PICK_HEAD") == ["/ws"])
        #expect(touched("/ws/.git/refs/heads/main") == ["/ws"])
    }

    @Test func fetchHeadTouchesTheOwningRepository() {
        // `git fetch <url> <ref>` advances only `FETCH_HEAD` (no local ref or working-tree change at all),
        // and the compare UI accepts `FETCH_HEAD` as a typed ref name for a diff scope, so a fetch that
        // only updates it must still be observed.
        #expect(touched("/ws/.git/FETCH_HEAD") == ["/ws"])
    }

    @Test func anyTopLevelNameMatchingTheHeadPatternTouchesTheOwningRepositoryButItsLockAndNestedFormsDoNot() {
        // The compare field accepts any resolvable ref as a diff scope, including `ORIG_HEAD` (which `git
        // update-ref ORIG_HEAD <sha>`, or an ordinary merge/rebase/reset, can rewrite on its own) and any
        // other custom `<NAME>_HEAD` a hook or script writes, so this is a shape match (one or more
        // uppercase letters, digits, or underscores followed by `_HEAD`), not a fixed enumeration.
        #expect(touched("/ws/.git/ORIG_HEAD") == ["/ws"])
        #expect(touched("/ws/.git/CUSTOM_HEAD") == ["/ws"])
        // The lock file git holds while writing the ref does not itself end in `_HEAD`, so it is dropped
        // the same way `index.lock`/`config.lock` are above.
        #expect(touched("/ws/.git/ORIG_HEAD.lock") == nil)
        // Not a top-level name (it has a `/`), the same reason `logs/HEAD` is dropped above.
        #expect(touched("/ws/.git/logs/ORIG_HEAD") == nil)
    }

    @Test func configAndConfigWorktreeTouchTheOwningRepositoryButConfigLockDoesNot() {
        // `git config core.fileMode false` (or a submodule's own ignore setting) rewrites one of these
        // files without touching the working tree, yet changes what `git status`/`git diff` report.
        #expect(touched("/ws/.git/config") == ["/ws"])
        #expect(touched("/ws/.git/config.worktree") == ["/ws"])
        #expect(touched("/ws/.git/config.lock") == nil)
    }

    @Test func reftableTablesListTouchesTheOwningRepositoryButObjectsDoesNot() {
        // A repository using the reftable ref storage format rewrites `reftable/tables.list` on every ref
        // update instead of touching anything under `refs/`.
        #expect(touched("/ws/.git/reftable/tables.list") == ["/ws"])
        #expect(touched("/ws/.git/objects/x") == nil)
    }

    @Test func aWorktreeGitDirOutsideTheRootMapsToTheWorkspaceRepository() {
        let worktreeRoot = Repository(workingDir: "/ws", gitDir: "/common/worktrees/ws", commonDir: "/common", ancestorWorkingDirs: [])
        let result = WorkspaceWatchEventAcceptance.touchedWorkingDirectories(
            forChangedPath: "/common/worktrees/ws/HEAD", repositories: [worktreeRoot], ignoredDirectories: { _ in [] })
        #expect(result == ["/ws"])
        let sharedRefResult = WorkspaceWatchEventAcceptance.touchedWorkingDirectories(
            forChangedPath: "/common/refs/heads/main", repositories: [worktreeRoot], ignoredDirectories: { _ in [] })
        #expect(sharedRefResult == ["/ws"])
    }

    @Test func aLinkedWorktreesCommonDirInfoExcludeMapsToTheWorkspaceRepository() {
        // A linked worktree's own gitDir (`<common>/worktrees/<name>`) has no `info/exclude` of its own;
        // that file lives only under the shared commonDir, which this must accept too.
        let worktreeRoot = Repository(workingDir: "/ws", gitDir: "/common/worktrees/ws", commonDir: "/common", ancestorWorkingDirs: [])
        let result = WorkspaceWatchEventAcceptance.touchedWorkingDirectories(
            forChangedPath: "/common/info/exclude", repositories: [worktreeRoot], ignoredDirectories: { _ in [] })
        #expect(result == ["/ws"])
    }

    @Test func aSubmodulesModulesDirectoryIndexMapsToTheSubmodule() {
        #expect(touched("/ws/.git/modules/A/index") == ["/ws/A", "/ws"])
        #expect(touched("/ws/.git/modules/A/modules/B/index") == ["/ws/A/B", "/ws/A", "/ws"])
    }

    @Test func aPathUnderAnIgnoredDirectoryIsDropped() {
        #expect(touched("/ws/build/output.o", ignored: ["/ws": ["/ws/build"]]) == nil)
    }

    @Test func aPathUnderAFreshlyUnignoredDirectoryIsAccepted() {
        // Before the `.gitignore` change removed the rule, "/ws/build" was ignored.
        #expect(touched("/ws/build/output.o", ignored: ["/ws": ["/ws/build"]]) == nil)
        // After: the caller's ignore set no longer names it (simulating a refresh after a `.gitignore`
        // edit), so the same path now resolves normally.
        #expect(touched("/ws/build/output.o", ignored: [:]) == ["/ws"])
    }

    @Test func ignoreIsScopedToTheOwningRepository() {
        // "/ws" ignoring "/ws/A" would be nonsensical (A is a submodule, not an ignorable directory of
        // root's own tree), but this pins that only the OWNING repository's ignore set is consulted: a
        // path inside A is checked against A's ignore set, never root's.
        #expect(touched("/ws/A/build/output.o", ignored: ["/ws": ["/ws/A/build"]]) == ["/ws/A", "/ws"])
        #expect(touched("/ws/A/build/output.o", ignored: ["/ws/A": ["/ws/A/build"]]) == nil)
    }
}
