import Testing

@testable import spacesterminalcore

/// The one rule every surface names a session by: a rename pins the name, otherwise the session
/// shows what it is doing right now, otherwise what it was launched as.
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

    @Test func launchTitleNamesASessionThatHasNotReportedAnything() { #expect(entry().effectiveTitle == "shell-1") }

    @Test func liveTitleReplacesTheLaunchTitle() { #expect(entry(runtimeTitle: "vim main.swift").effectiveTitle == "vim main.swift") }

    @Test func renamePinsTheNameAgainstLiveTitleChanges() {
        #expect(entry(userTitle: "deploy", runtimeTitle: "vim main.swift").effectiveTitle == "deploy")
    }

    /// Clearing the rename hands the name back to the live title — the pin is the only thing that
    /// was holding it.
    @Test func clearingTheRenameRevertsToTheLiveTitle() {
        #expect(entry(userTitle: nil, runtimeTitle: "vim main.swift").effectiveTitle == "vim main.swift")
    }

    /// A program that clears its title (or sets a blank one) must not leave the session nameless.
    @Test func blankTitlesFallThroughToTheNextLevel() {
        #expect(entry(runtimeTitle: "").effectiveTitle == "shell-1")
        #expect(entry(runtimeTitle: "   ").effectiveTitle == "shell-1")
        #expect(entry(userTitle: "  ", runtimeTitle: "vim main.swift").effectiveTitle == "vim main.swift")
        #expect(entry(userTitle: " ", runtimeTitle: " ").effectiveTitle == "shell-1")
    }

    @Test func liveWorkingDirectoryReplacesTheLaunchDirectory() {
        #expect(entry().effectiveWorkingDirectory == "/repo")
        #expect(entry(runtimeWorkingDirectory: "/repo/apps/web").effectiveWorkingDirectory == "/repo/apps/web")
    }
}
