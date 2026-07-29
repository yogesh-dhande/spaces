import Testing

@testable import spacesterminalcore

/// The two things a session is called: the name that identifies it (its rename, else the name it was
/// launched under) and the title its program reports, which never becomes the name.
@Suite struct TerminalSessionDisplayTitleTests {
    private func entry(userTitle: String? = nil, runtimeTitle: String? = nil, launchTitle: String = "shell-1", runtimeWorkingDirectory: String? = nil)
        -> TerminalSessionCatalogEntry
    {
        TerminalSessionCatalogEntry(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: "session-1", title: launchTitle, workingDirectory: "/repo", shell: "/bin/zsh", command: nil,
                createdAt: "2026-01-01T00:00:00Z", workspaceID: "workspace-1", kind: .shell, userTitle: userTitle),
            runtimeState: TerminalSessionRuntimeState(
                sessionID: "session-1", servicePID: 1, childPID: nil, state: .running, updatedAt: "2026-01-01T00:00:01Z", title: runtimeTitle,
                workingDirectory: runtimeWorkingDirectory), attachmentSnapshot: .init(), paths: TerminalSessionPaths(rootDirectory: "/tmp/session-1"),
            isControlAvailable: true, isSubscriptionAvailable: true)
    }

    @Test func launchTitleNamesASessionNobodyHasRenamed() { #expect(entry().name == "shell-1") }

    /// The whole point of the split: a program retitling itself describes the session without renaming
    /// it, so a shell the user opened stays findable as `shell-1` while it runs an editor.
    @Test func liveTitleNeverReplacesTheName() {
        let session = entry(runtimeTitle: "vim main.swift")
        #expect(session.name == "shell-1")
        #expect(session.liveTitle == "vim main.swift")
    }

    @Test func renameBecomesTheNameAndLeavesTheLiveTitleAlone() {
        let session = entry(userTitle: "deploy", runtimeTitle: "vim main.swift")
        #expect(session.name == "deploy")
        #expect(session.liveTitle == "vim main.swift")
    }

    /// Clearing the rename restores the name the session was launched under — the only way back from a
    /// rename. A blank stored rename is what clearing writes.
    @Test func clearedRenameRestoresTheLaunchName() {
        #expect(entry(userTitle: nil, runtimeTitle: "vim main.swift").name == "shell-1")
        #expect(entry(userTitle: "  ", runtimeTitle: "vim main.swift").name == "shell-1")
    }

    /// A program that clears its title stops describing itself; the row shows its name and nothing
    /// else rather than a blank second line.
    @Test func blankLiveTitleReadsAsNoLiveTitle() {
        #expect(entry(runtimeTitle: "").liveTitle == nil)
        #expect(entry(runtimeTitle: "   ").liveTitle == nil)
        #expect(entry().liveTitle == nil)
    }

    @Test func liveWorkingDirectoryReplacesTheLaunchDirectory() {
        #expect(entry().effectiveWorkingDirectory == "/repo")
        #expect(entry(runtimeWorkingDirectory: "/repo/apps/web").effectiveWorkingDirectory == "/repo/apps/web")
    }
}
