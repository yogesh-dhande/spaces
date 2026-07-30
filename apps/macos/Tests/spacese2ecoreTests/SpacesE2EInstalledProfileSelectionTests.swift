import Foundation
import XCTest
import spacesterminalcore

@testable import spacese2ecore

/// `spacese2e --installed-profile <command>` is the one route from a QA harness to the profile a user's own
/// app, daemon, and CLI serve. These cover both halves of that route: which commands the selector accepts, and
/// that an accepted one resolves the installed profile rather than the checkout's development profile.
///
/// Nothing here touches the real `~/.spaces`: every resolution is driven with an injected home directory, and
/// the last test states the guarantee directly — even a bound process is refused the account's real installed
/// profile while it is a test host.
final class SpacesE2EInstalledProfileSelectionTests: XCTestCase {
    private var tempHomeURL: URL!

    override func setUpWithError() throws {
        tempHomeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHomeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHomeURL, FileManager.default.fileExists(atPath: tempHomeURL.path) { try FileManager.default.removeItem(at: tempHomeURL) }
        tempHomeURL = nil
    }

    /// The ordinary invocation is untouched: without the selector nothing is classified, because the command
    /// is acting on the development profile the binary belongs to, which is nobody's live state.
    func testInvocationWithoutTheSelectorPassesThroughUnclassified() throws {
        for arguments in [["surface-snapshot", "--spaces-pid", "42"], ["archive-workspace", "--workspace-dir", "/tmp/workspace"]] {
            let invocation = try SpacesE2EInstalledProfileSelection.parse(arguments: arguments)
            XCTAssertEqual(invocation.commandArguments, arguments)
            XCTAssertFalse(invocation.targetsInstalledProfile)
        }
    }

    /// A refused command is refused loudly, names itself, and carries the classified reason, so the person
    /// running it is told what the command would have done to a live profile rather than that it "failed".
    func testRefusedCommandIsRefusedWithItsReason() throws {
        let arguments = ["--installed-profile", "archive-workspace", "--workspace-dir", "/tmp/workspace"]

        XCTAssertThrowsError(try SpacesE2EInstalledProfileSelection.parse(arguments: arguments)) { error in
            guard case SpacesE2EInstalledProfileRefusal.commandRefused(let commandName, let reason) = error else {
                return XCTFail("Expected commandRefused, got \(error).")
            }
            XCTAssertEqual(commandName, "archive-workspace")
            XCTAssertFalse(reason.isEmpty, "A refusal reason is written for the person running the command.")
            let message = String(describing: error)
            XCTAssertTrue(message.contains("archive-workspace"), "The refusal must name the command: \(message)")
            XCTAssertTrue(message.contains(reason), "The refusal must carry the classified reason: \(message)")
            XCTAssertTrue(message.contains("~/.spaces"), "The refusal must name the profile it protected: \(message)")
        }
    }

    /// Every command that removes existing projects or workspaces, or creates them where nothing can remove
    /// them again, stays refused. This is the rule the whole gate exists for, so it is asserted as a set
    /// rather than one representative command.
    func testCommandsThatCreateOrRemoveProjectsAndWorkspacesAreRefused() throws {
        let refusedCommands = [
            "seed-fixture", "register-project", "create-workspace", "cleanup-fixtures", "stop-fixtures", "archive-workspace", "hide-workspace",
            "e2e",
        ]

        for commandName in refusedCommands {
            XCTAssertThrowsError(
                try SpacesE2EInstalledProfileSelection.parse(arguments: ["--installed-profile", commandName]), "Expected \(commandName) to be refused."
            ) { error in
                guard case SpacesE2EInstalledProfileRefusal.commandRefused = error else {
                    return XCTFail("Expected \(commandName) to be classified as refused, got \(error).")
                }
            }
        }
    }

    /// Overwriting or deleting state a sweep did not create is refused even where the change looks small and
    /// easy to describe as temporary. Nothing in this tooling captures what a workspace had configured before
    /// it writes, so "the sweep clears it again afterwards" restores nothing — and clearing the agent rows of
    /// a workspace whose agents are still running is a state the product's own UI cannot produce at all. Each
    /// refusal has to say which of those it is, because that reason is the argument for the classification.
    func testCommandsThatDestroyStateTheSweepDidNotCreateAreRefused() throws {
        let expectedReasonPhrases = [
            "set-workspace-agent-launchers": ["configured coding-agent launcher list", "no record of what was there"],
            "set-workspace-browser-session-urls": ["browser session URLs", "no record of what was there"],
            "clear-workspace-agent-windows": ["did not create", "terminals stay live"],
        ]

        for (commandName, phrases) in expectedReasonPhrases {
            XCTAssertThrowsError(
                try SpacesE2EInstalledProfileSelection.parse(arguments: ["--installed-profile", commandName, "--workspace-dir", "/tmp/workspace"]),
                "Expected \(commandName) to be refused."
            ) { error in
                guard case SpacesE2EInstalledProfileRefusal.commandRefused(let refusedCommand, let reason) = error else {
                    return XCTFail("Expected \(commandName) to be classified as refused, got \(error).")
                }
                XCTAssertEqual(refusedCommand, commandName)
                for phrase in phrases {
                    XCTAssertTrue(reason.contains(phrase), "\(commandName)'s refusal must say what it would destroy (missing '\(phrase)'): \(reason)")
                }
            }
        }
    }

    /// The other half of that line, pinned so it is not "corrected" later: a command that does exactly what a
    /// user can already do to their own profile from the app stays permitted. Stopping a workspace is an
    /// action the UI offers, and losing the contents of the terminals it closes is inherent to stopping a
    /// workspace rather than something this route adds. `launch-workspace-agent` stays permitted with it, so
    /// an already-configured launcher's lifecycle is still testable on the installed profile even though the
    /// command that would REPLACE that configuration is refused.
    func testCommandsTheProductUIAlreadyOffersStayPermitted() throws {
        for commandName in ["stop-workspace", "launch-workspace-agent"] {
            let invocation = try SpacesE2EInstalledProfileSelection.parse(
                arguments: ["--installed-profile", commandName, "--workspace-dir", "/tmp/workspace"])
            XCTAssertTrue(invocation.targetsInstalledProfile, "Expected \(commandName) to be permitted against the installed profile.")
        }
    }

    /// A command with no classification is refused rather than assumed safe, so a command added later cannot
    /// reach a live profile by omission. The message points at the one place a classification is declared.
    func testUnclassifiedCommandFailsClosed() throws {
        XCTAssertThrowsError(try SpacesE2EInstalledProfileSelection.parse(arguments: ["--installed-profile", "erase-everything"])) { error in
            guard case SpacesE2EInstalledProfileRefusal.commandUnclassified(let commandName) = error else {
                return XCTFail("Expected commandUnclassified, got \(error).")
            }
            XCTAssertEqual(commandName, "erase-everything")
            XCTAssertTrue(
                String(describing: error).contains("byCommandName"), "The refusal must point at where a classification is declared: \(error)")
        }
    }

    /// The selector alone says nothing about what may run, so it is refused rather than applied to whatever
    /// ArgumentParser would have done next.
    func testSelectorWithoutACommandIsRefused() throws {
        XCTAssertThrowsError(try SpacesE2EInstalledProfileSelection.parse(arguments: ["--installed-profile", "--help"])) { error in
            guard case SpacesE2EInstalledProfileRefusal.noCommandNamed = error else { return XCTFail("Expected noCommandNamed, got \(error).") }
        }
    }

    /// An accepted read-only command reaches the installed profile — and reaches it even from a binary that
    /// would otherwise derive this checkout's development profile, which is the whole point of the selector.
    /// The selector itself is consumed, so ArgumentParser sees only the command it knows.
    func testAllowedReadOnlyCommandResolvesTheInstalledProfile() throws {
        let invocation = try SpacesE2EInstalledProfileSelection.parse(arguments: ["--installed-profile", "surface-snapshot", "--spaces-pid", "42"])
        XCTAssertTrue(invocation.targetsInstalledProfile)
        XCTAssertEqual(invocation.commandArguments, ["surface-snapshot", "--spaces-pid", "42"])

        let repoRoot = try makeFakeRepoRoot()
        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path,
            executablePath: repoRoot.appendingPathComponent("apps/macos/.build/debug/spacese2e").path,
            gitProbe: StubGitProfileProbe(context: SpacesDevelopmentContext(worktreeRoot: repoRoot.path, branchName: "feature/x")),
            bindsInstalledProfile: invocation.targetsInstalledProfile)

        XCTAssertEqual(profile.source, .explicitInstalledProfile)
        XCTAssertEqual(profile.rootDirectory, tempHomeURL.appendingPathComponent(".spaces").path)
        XCTAssertEqual(profile.databasePath, tempHomeURL.appendingPathComponent(".spaces/spaces.db").path)
        XCTAssertTrue(profile.isInstalledProfile)
        XCTAssertEqual(profile.defaultRouterPort, SpacesProfile.installedRouterPort)
    }

    /// The reversible half of the permitted set reaches the same profile: ending a session a sweep started is
    /// what keeps a resource measurement of the installed build from being taken through an abnormal teardown.
    func testAllowedReversibleCommandResolvesTheInstalledProfile() throws {
        let invocation = try SpacesE2EInstalledProfileSelection.parse(arguments: ["terminate-terminal-session", "session-123", "--installed-profile"])
        XCTAssertTrue(invocation.targetsInstalledProfile)
        XCTAssertEqual(invocation.commandArguments, ["terminate-terminal-session", "session-123"])

        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil),
            bindsInstalledProfile: invocation.targetsInstalledProfile)

        XCTAssertTrue(profile.isInstalledProfile)
        XCTAssertEqual(profile.runtimeDirectory, tempHomeURL.appendingPathComponent(".spaces/runtime").path)
    }

    /// A bound process serves the installed profile WHOLE. An inherited `SPACES_DB_PATH` or `SPACES_RUNTIME_DIR`
    /// is dropped rather than merged, so the process cannot end up reading the installed database while its
    /// sockets and session directories sit under some other profile's runtime root.
    func testInstalledProfileBindingIgnoresInheritedProfileOverrides() throws {
        let strayRoot = tempHomeURL.appendingPathComponent("stray", isDirectory: true)

        let profile = try SpacesProfile.resolve(
            environment: [
                SpacesProfile.databasePathEnvironmentVariable: strayRoot.appendingPathComponent("spaces.db").path,
                SpacesProfile.runtimeDirectoryEnvironmentVariable: strayRoot.appendingPathComponent("runtime").path,
            ], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil),
            bindsInstalledProfile: true)

        XCTAssertEqual(profile.databasePath, tempHomeURL.appendingPathComponent(".spaces/spaces.db").path)
        XCTAssertEqual(profile.runtimeDirectory, tempHomeURL.appendingPathComponent(".spaces/runtime").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayRoot.path), "The dropped overrides must not have been created either.")
    }

    /// The binding is for `spacese2e`, not for tests. A test process stays refused the account's real installed
    /// profile however it asked for it, so this suite can never read or write the profile a user relies on.
    func testTestHostIsStillRefusedTheAccountsInstalledProfile() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(SpacesProfile.accountHomeDirectoryPath()), isDirectory: true)

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: accountHomeURL, currentDirectoryPath: tempHomeURL.path,
                executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil),
                bindsInstalledProfile: true)
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let component, let path) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertEqual(component, .database)
            XCTAssertEqual(path, accountHomeURL.appendingPathComponent(".spaces/spaces.db").path)
        }
    }

    private func makeFakeRepoRoot() throws -> URL {
        let repoRoot = tempHomeURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageURL = repoRoot.appendingPathComponent("apps/macos/Package.swift")
        try FileManager.default.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("".utf8).write(to: packageURL)
        return repoRoot
    }
}

private struct StubGitProfileProbe: SpacesGitProfileProbe {
    let context: SpacesDevelopmentContext?

    func resolveDevelopmentContext(repoRootPath _: String) throws -> SpacesDevelopmentContext? { context }
}
