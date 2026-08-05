import Foundation
import XCTest

@testable import spacesterminalcore
@testable import workspacecore

final class SpacesProfileTests: XCTestCase {
    private var tempHomeURL: URL!

    override func setUpWithError() throws {
        tempHomeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempHomeURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHomeURL, FileManager.default.fileExists(atPath: tempHomeURL.path) { try FileManager.default.removeItem(at: tempHomeURL) }
        tempHomeURL = nil
    }

    func testResolveInstalledFallbackUsesSpacesDirectory() throws {
        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.source, .installedFallback)
        XCTAssertEqual(profile.databasePath, tempHomeURL.appendingPathComponent(".spaces/spaces.db").path)
        XCTAssertEqual(profile.runtimeDirectory, tempHomeURL.appendingPathComponent(".spaces/runtime").path)
    }

    func testResolveStopsSearchingAtFilesystemRootWhenExecutableIsOutsideRepo() throws {
        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/tmp/spacesPackageTests.xctest/Contents/MacOS/spacesPackageTests", gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.source, .installedFallback)
        XCTAssertEqual(profile.databasePath, tempHomeURL.appendingPathComponent(".spaces/spaces.db").path)
    }

    /// Test targets create and mutate real terminal-session state through the resolved profile, so a test
    /// process that reaches a live profile writes fixture sessions into a database the app or daemon is
    /// serving. Resolution refuses that instead of falling through to it — here via the installed fallback.
    func testResolveRefusesInstalledProfileForTestHost() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: accountHomeURL, currentDirectoryPath: tempHomeURL.path,
                executablePath: "/tmp/spacesPackageTests.xctest/Contents/MacOS/spacesPackageTests", gitProbe: StubGitProfileProbe(context: nil))
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let component, let path) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertEqual(component, .database)
            XCTAssertEqual(path, accountHomeURL.appendingPathComponent(".spaces/spaces.db").path)
            XCTAssertEqual(error.localizedDescription, String(describing: error))
        }
    }

    /// The development branch resolves a per-worktree profile the developer's debug app serves, so it is
    /// refused on the same terms as the installed one. `current()` cannot reach this branch from a test
    /// host (the test executable is the toolchain's, outside any checkout), so it is driven through
    /// `resolve` with a repo-built executable path.
    func testResolveRefusesDevelopmentProfileForTestHost() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)
        let repoRoot = try makeFakeRepoRoot()
        let context = SpacesDevelopmentContext(worktreeRoot: tempHomeURL.appendingPathComponent("worktree").path, branchName: "feature/x")
        let expectedRefusedRoot = accountHomeURL.appendingPathComponent(
            ".spaces-dev/profiles/spaces/feature-x-\(SpacesProfile.shortStableHash(SpacesProfile.canonicalPath(context.worktreeRoot)))")
        addTeardownBlock { try? FileManager.default.removeItem(at: expectedRefusedRoot) }

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: accountHomeURL, currentDirectoryPath: repoRoot.path,
                executablePath: repoRoot.appendingPathComponent("apps/macos/.build/debug/spacesd").path,
                gitProbe: StubGitProfileProbe(context: context))
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let component, let path) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertEqual(component, .database)
            XCTAssertTrue(
                path.hasPrefix(accountHomeURL.appendingPathComponent(".spaces-dev/profiles").path),
                "Expected the refused path to be a development profile, got \(path).")
        }
    }

    /// `SPACES_DB_PATH` names an ephemeral throwaway profile only. A real profile — installed or
    /// development — is identified by where the running binary lives, so the variable pointing into one of
    /// this account's live profile roots is always a leaked binding rather than a way to select a profile.
    /// The refusal is universal, not test-only: the failure it prevents is a production one, where a daemon
    /// serving `~/.spaces` inherited the variable through an agent hook and was reclassified as a
    /// development profile that then took (and persisted) a development-range Device API port.
    func testResolveRefusesExplicitOverrideInsideEitherLiveProfileRoot() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)
        let overridePaths = [
            accountHomeURL.appendingPathComponent(".spaces/spaces.db").path,
            accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/main-abc123/spaces.db").path,
        ]
        // Never created while the refusal holds; cleaned up so proving this test fails without the guard
        // leaves nothing behind in the developer's real profile.
        addTeardownBlock { try? FileManager.default.removeItem(at: accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/main-abc123")) }

        for overridePath in overridePaths {
            XCTAssertThrowsError(
                try SpacesProfile.resolve(
                    environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
                    currentDirectoryPath: tempHomeURL.path, executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
                    gitProbe: StubGitProfileProbe(context: nil)), "Expected \(overridePath) to be refused."
            ) { error in
                guard case SpacesProfileResolutionError.explicitDatabasePathInsideLiveUserProfile(let path) = error else {
                    return XCTFail("Expected explicitDatabasePathInsideLiveUserProfile for \(overridePath), got \(error).")
                }
                XCTAssertEqual(path, overridePath)
                XCTAssertEqual(error.localizedDescription, String(describing: error))
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/main-abc123").path),
            "A refused resolution must not have created the profile directory.")
    }

    /// What a profile IS comes from its resolved root, not from the branch that produced it. An explicit
    /// database path inside a home's `.spaces` resolves through the override branch and is still the
    /// installed profile, so every installed-only rule — the canonical Device API port, the well-known
    /// router port, the installed daemon binaries, the installed systemd unit — applies to it.
    func testInstalledRootIsTheInstalledProfileWhicheverBranchResolvedIt() throws {
        let viaFallback = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))
        let viaExplicitPath = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: tempHomeURL.appendingPathComponent(".spaces/spaces.db").path],
            homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(viaFallback.source, .installedFallback)
        XCTAssertEqual(viaExplicitPath.source, .explicitDatabasePath)
        XCTAssertEqual(viaFallback.rootDirectory, viaExplicitPath.rootDirectory)
        XCTAssertTrue(viaFallback.isInstalledProfile)
        XCTAssertTrue(viaExplicitPath.isInstalledProfile)
        XCTAssertEqual(viaExplicitPath.defaultRouterPort, SpacesProfile.installedRouterPort)
    }

    /// The companion direction, so installed-ness is a real test of the root rather than something that
    /// answers true for anything: a development profile is not the installed one whichever branch produced
    /// it, and it keeps its own derived router port.
    func testDevelopmentRootIsNotTheInstalledProfile() throws {
        let repoRoot = try makeFakeRepoRoot()
        let context = SpacesDevelopmentContext(worktreeRoot: tempHomeURL.appendingPathComponent("worktree").path, branchName: "feature/x")

        let worktreeProfile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path,
            executablePath: repoRoot.appendingPathComponent("apps/macos/.build/debug/spacesd").path, gitProbe: StubGitProfileProbe(context: context))
        let ephemeralProfile = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: tempHomeURL.appendingPathComponent("scratch/spaces.db").path],
            homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertFalse(worktreeProfile.isInstalledProfile)
        XCTAssertFalse(ephemeralProfile.isInstalledProfile)
        XCTAssertNotEqual(ephemeralProfile.defaultRouterPort, SpacesProfile.installedRouterPort)
    }

    /// The mixed state: a test binds its own temporary database but inherits a `SPACES_RUNTIME_DIR` left in
    /// the shell by an E2E harness that split the two. The database half looks isolated
    /// while session directories, sockets, and the daemon instance lock would land in a live runtime root,
    /// so the runtime half is refused on the same terms — and the error names that half, not the database.
    func testResolveRefusesLiveRuntimeDirectoryEvenWithAnIsolatedDatabaseForTestHost() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)
        let isolatedDatabasePath = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/spaces.db").path
        let liveRuntimePath = accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/main-abc123/runtime").path
        addTeardownBlock { try? FileManager.default.removeItem(at: accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/main-abc123")) }

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [
                    SpacesProfile.databasePathEnvironmentVariable: isolatedDatabasePath,
                    SpacesProfile.runtimeDirectoryEnvironmentVariable: liveRuntimePath,
                ], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
                executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let component, let path) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertEqual(component, .runtimeDirectory)
            XCTAssertEqual(path, liveRuntimePath)
            XCTAssertTrue(
                String(describing: error).contains(SpacesProfile.runtimeDirectoryEnvironmentVariable),
                "The message must name the override to change: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveRuntimePath), "A refused runtime override must not have been created.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: isolatedDatabasePath).deletingLastPathComponent().path),
            "A refused resolution must not have created the profile root either.")
    }

    /// A runtime override spelled as a live root EXACTLY is refused, for each root. The root is live user
    /// state itself, so resolving onto it would put session directories, sockets and the daemon instance
    /// lock straight into it — the same harm as resolving inside it.
    func testResolveRefusesRuntimeDirectorySpelledAsALiveRootExactly() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)
        let liveRoots = [
            accountHomeURL.appendingPathComponent(".spaces", isDirectory: true).path,
            accountHomeURL.appendingPathComponent(".spaces-dev/profiles", isDirectory: true).path,
        ]

        for liveRoot in liveRoots {
            // The database half is isolated, so only the runtime spelling can be what is refused. Its
            // profile root is a fresh temporary directory, which doubles as the create-nothing probe: the
            // live roots already exist on a developer machine, so their presence proves nothing.
            let isolatedProfileRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let isolatedDatabasePath = isolatedProfileRoot.appendingPathComponent("spaces.db", isDirectory: false).path

            XCTAssertThrowsError(
                try SpacesProfile.resolve(
                    environment: [
                        SpacesProfile.databasePathEnvironmentVariable: isolatedDatabasePath,
                        SpacesProfile.runtimeDirectoryEnvironmentVariable: liveRoot,
                    ], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
                    executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil)),
                "Expected \(liveRoot) to be refused as a runtime directory."
            ) { error in
                guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let component, let path) = error else {
                    return XCTFail("Expected testHostRefusedLiveUserProfile for \(liveRoot), got \(error).")
                }
                XCTAssertEqual(component, .runtimeDirectory)
                XCTAssertEqual(path, liveRoot)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: isolatedProfileRoot.path),
                "A refused resolution must not have created anything, including the profile root.")
        }
    }

    /// Both halves bound outside the live roots — the normal isolated test — still resolves, and the
    /// runtime override is honoured rather than derived.
    func testResolveAcceptsTemporaryDatabaseAndRuntimeDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let databasePath = root.appendingPathComponent("spaces.db", isDirectory: false).path
        let runtimePath = root.appendingPathComponent("runtime", isDirectory: true).path

        let profile = try SpacesProfile.resolve(
            environment: [
                SpacesProfile.databasePathEnvironmentVariable: databasePath, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimePath,
            ], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.databasePath, databasePath)
        XCTAssertEqual(profile.runtimeDirectory, runtimePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtimePath), "An accepted runtime directory is still created.")
    }

    /// The refusal must not swallow the mechanism the whole suite isolates with: an override outside the
    /// live roots — what every isolated test binds — still resolves.
    func testResolveAcceptsExplicitOverrideOutsideLiveProfileRoots() throws {
        let overridePath = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/spaces.db").path

        let profile = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
            currentDirectoryPath: tempHomeURL.path, executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
            gitProbe: StubGitProfileProbe(context: nil))
        addTeardownBlock { try? FileManager.default.removeItem(at: URL(fileURLWithPath: overridePath).deletingLastPathComponent()) }

        XCTAssertEqual(profile.source, .explicitDatabasePath)
        XCTAssertEqual(profile.databasePath, overridePath)
    }

    /// Containment is by path component, not string prefix: a sibling of a live root whose name merely
    /// extends it is not inside it. The sibling must live in the real account home for the predicate to see
    /// it at all, so its name carries a UUID — the test can then only ever delete a directory it created.
    func testResolveAcceptsOverrideInDirectoryWhoseNameExtendsALiveProfileRoot() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)
        let siblingRoot = accountHomeURL.appendingPathComponent(".spaces-dev-sibling-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: siblingRoot) }
        let overridePath = siblingRoot.appendingPathComponent("spaces.db", isDirectory: false).path

        let profile = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
            currentDirectoryPath: tempHomeURL.path, executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
            gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.databasePath, overridePath)
    }

    /// The refusal has to hold for the profile the process actually uses, not only for a directly called
    /// `resolve`: every persistence path reaches the database through `current()`.
    func testCurrentProfileRefusesInstalledProfileForTestHost() throws {
        let accountHomePath = try XCTUnwrap(currentUserAccountHomePath())

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil, "HOME": accountHomePath,
        ]) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            XCTAssertThrowsError(try SpacesProfile.current())
            XCTAssertThrowsError(try DatabaseLocator.defaultPath())
        }
    }

    /// Issue #322: the distinguishing rule callers need is "resolve, or nil if there is genuinely no
    /// profile, rethrowing a refusal" — `nilUnlessRefused` is that rule, isolated from `current()`/`resolve()`
    /// so both directions are provable without touching the filesystem, `HOME`, or account state.
    func testNilUnlessRefusedDegradesAGenuineResolutionFailureToNil() throws {
        let result = try SpacesProfile.nilUnlessRefused { () throws -> Int in
            throw SpacesProfileResolutionError.repoBuiltGitProbeFailed(executablePath: "/tmp/spacesd", repoRoot: "/tmp", underlyingError: nil)
        }
        XCTAssertNil(result)
    }

    /// The other half of the same rule: a refusal is not a "no profile" outcome and must come back out as
    /// a thrown error even though every other `SpacesProfileResolutionError` case collapses to `nil` here.
    func testNilUnlessRefusedRethrowsTestHostRefusalInsteadOfDegradingToNil() {
        XCTAssertThrowsError(
            try SpacesProfile.nilUnlessRefused { () throws -> Int in
                throw SpacesProfileResolutionError.testHostRefusedLiveUserProfile(component: .database, path: "/Users/tester/.spaces/spaces.db")
            }
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
        }
    }

    /// Every refusal is loud, not just the test-host one: a `SPACES_DB_PATH` pointing into a live profile
    /// root means this process is not allowed to resolve one, which is a different outcome from there being
    /// no profile to resolve, and a caller must not be able to fold the two together.
    func testNilUnlessRefusedRethrowsAnExplicitDatabasePathRefusalInsteadOfDegradingToNil() {
        XCTAssertThrowsError(
            try SpacesProfile.nilUnlessRefused { () throws -> Int in
                throw SpacesProfileResolutionError.explicitDatabasePathInsideLiveUserProfile(path: "/Users/tester/.spaces/spaces.db")
            }
        ) { error in
            guard case SpacesProfileResolutionError.explicitDatabasePathInsideLiveUserProfile = error else {
                return XCTFail("Expected explicitDatabasePathInsideLiveUserProfile, got \(error).")
            }
        }
    }

    /// Wires the mechanism above to the real entry point every product call site uses. Before issue
    /// #322's fix, every one of those seven call sites wrapped `SpacesProfile.current()` directly in
    /// `try?`, which — proven by the commented-out line below — silently takes the same "no profile"
    /// branch on a refusal that it takes on a database that plain does not exist yet. This test fails
    /// every run against that old shape, because `try?` on a throwing call can never satisfy
    /// `XCTAssertThrowsError`.
    func testCurrentOrNilIfUnresolvedRethrowsTestHostRefusalInsteadOfDegradingToNil() throws {
        let accountHomePath = try XCTUnwrap(currentUserAccountHomePath())

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil, "HOME": accountHomePath,
        ]) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            // The bug this guards against: `let profile = try? SpacesProfile.currentOrNilIfUnresolved()`
            // here would compile and pass with `profile == nil`, exactly like the seven call sites did
            // before the fix. `currentOrNilIfUnresolved()` must be called with `try` and observed to throw.
            XCTAssertThrowsError(try SpacesProfile.currentOrNilIfUnresolved()) { error in
                guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile = error else {
                    return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
                }
            }
        }
    }

    /// The legitimate use of `currentOrNilIfUnresolved()` — an isolated profile resolves normally, exactly
    /// like `current()` — must keep working, so the fix has not turned a non-fatal "no profile" path into
    /// a crash for every other test in the suite.
    func testCurrentOrNilIfUnresolvedResolvesNormallyForAnIsolatedProfile() throws {
        let databasePath = tempHomeURL.appendingPathComponent("profiles/current-or-nil-if-unresolved/spaces.db").path

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: databasePath, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil,
        ]) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            let profile = try SpacesProfile.currentOrNilIfUnresolved()
            XCTAssertEqual(profile?.databasePath, databasePath)
        }
    }

    /// Issue #322 follow-up: `TerminalOverviewSignal.post` and `SpacesDevicePairingClient.localMacClientInstallationID`
    /// cannot use `currentOrNilIfUnresolved()`'s throw-the-refusal shape — neither is in a `throws`
    /// context, and unlike the `spacesui` sites neither can safely trap either (see
    /// `currentOrNilLoggingRefusal`'s doc comment). `currentOrNilLoggingRefusal()` is their mechanism:
    /// still `nil` on a refusal (so the caller's existing degrade fires unchanged), but the refusal is
    /// reported through `diagnoseRefusal` instead of vanishing indistinguishably into the same `nil` a
    /// `repoBuiltGitProbeFailed` would produce. A bare `try?` — what both call sites carried before this
    /// fix — can never invoke that callback, so this test fails every run against that old shape.
    func testCurrentOrNilLoggingRefusalReportsTheRefusalInsteadOfSilentlyDegrading() throws {
        let accountHomePath = try XCTUnwrap(currentUserAccountHomePath())
        let reportedError = LockedValueBox<SpacesProfileResolutionError>()

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil, "HOME": accountHomePath,
        ]) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            let profile = SpacesProfile.currentOrNilLoggingRefusal(diagnoseRefusal: { reportedError.set($0) })

            XCTAssertNil(profile, "A refusal must still degrade to nil for the caller's existing no-profile branch.")
            guard case .testHostRefusedLiveUserProfile = try XCTUnwrap(reportedError.value) else {
                return XCTFail("Expected diagnoseRefusal to report testHostRefusedLiveUserProfile, got \(String(describing: reportedError.value)).")
            }
        }
    }

    /// The companion direction: an ordinary successful resolution must not spuriously invoke
    /// `diagnoseRefusal` — it exists for the refusal only, not as a general resolution-completed hook.
    func testCurrentOrNilLoggingRefusalDoesNotReportOnASuccessfulResolution() throws {
        let databasePath = tempHomeURL.appendingPathComponent("profiles/current-or-nil-logging-refusal/spaces.db").path
        let diagnoseWasCalled = LockedValueBox<Bool>()

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: databasePath, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil,
        ]) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            let profile = SpacesProfile.currentOrNilLoggingRefusal(diagnoseRefusal: { _ in diagnoseWasCalled.set(true) })

            XCTAssertEqual(profile?.databasePath, databasePath)
            XCTAssertNil(diagnoseWasCalled.value, "diagnoseRefusal must not run for a successful resolution.")
        }
    }

    func testResolveExplicitDatabaseOverrideWins() throws {
        let overridePath = tempHomeURL.appendingPathComponent("profiles/custom/spaces.db").path

        let profile = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
            currentDirectoryPath: tempHomeURL.path, executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
            gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.source, .explicitDatabasePath)
        XCTAssertEqual(profile.databasePath, overridePath)
        XCTAssertEqual(profile.rootDirectory, tempHomeURL.appendingPathComponent("profiles/custom").path)
        XCTAssertEqual(profile.runtimeDirectory, tempHomeURL.appendingPathComponent("profiles/custom/runtime").path)
    }

    func testResolveDevelopmentWorktreeUsesBranchSlugAndHash() throws {
        let repoRoot = try makeFakeRepoRoot()
        let worktreeRoot = tempHomeURL.appendingPathComponent("worktrees/feature-a").path
        let context = SpacesDevelopmentContext(worktreeRoot: worktreeRoot, branchName: "Feature/Add IPC")

        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path,
            executablePath: repoRoot.appendingPathComponent("apps/macos/.build/debug/spaces").path, gitProbe: StubGitProfileProbe(context: context))

        let expectedSlug = "feature-add-ipc"
        let expectedHash = SpacesProfile.shortStableHash(SpacesProfile.canonicalPath(worktreeRoot))
        let expectedRoot = tempHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/\(expectedSlug)-\(expectedHash)").path

        XCTAssertEqual(profile.source, .developmentWorktree)
        XCTAssertEqual(profile.rootDirectory, expectedRoot)
        XCTAssertEqual(profile.databasePath, "\(expectedRoot)/spaces.db")
        XCTAssertEqual(profile.runtimeDirectory, "\(expectedRoot)/runtime")
        XCTAssertEqual(profile.branchSlug, expectedSlug)
        XCTAssertEqual(profile.worktreeHash, expectedHash)
    }

    /// A development build deployed onto a device has no checkout to derive a profile from, so it states
    /// which profile it serves by where it was installed: inside that profile's own root. Resolution reads
    /// the binary's own location, which is why a `HOME` that has nothing to do with the deployment (what
    /// systemd or an SSH command happens to hand the daemon) cannot move it onto another profile — least of
    /// all onto the installed one, whose production database it would then open.
    func testResolveDeployedDevelopmentProfileFromTheExecutablesOwnLocation() throws {
        let profileRoot = tempHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/feature-add-ipc-0123456789ab", isDirectory: true)
        let executablePath = profileRoot.appendingPathComponent("daemon/current/bin/spacesd", isDirectory: false).path
        // The resolved root comes from the canonicalized executable path, so the expectation is spelled the
        // same way rather than assuming the temporary directory has no symlinked ancestor.
        let expectedRoot = SpacesProfile.canonicalPath(profileRoot.path)

        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL.appendingPathComponent("unrelated-home", isDirectory: true),
            currentDirectoryPath: tempHomeURL.path, executablePath: executablePath, gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.source, .deployedDevelopmentProfile)
        XCTAssertEqual(profile.rootDirectory, expectedRoot)
        XCTAssertEqual(profile.databasePath, "\(expectedRoot)/spaces.db")
        XCTAssertEqual(profile.runtimeDirectory, "\(expectedRoot)/runtime")
        // The directory name a deployment was given carries the worktree identity of the profile it
        // mirrors, and that identity is what labels the device's Bonjour service.
        XCTAssertEqual(profile.branchSlug, "feature-add-ipc")
        XCTAssertEqual(profile.worktreeHash, "0123456789ab")
    }

    /// An explicit `SPACES_DB_PATH` still wins over the deployed-profile rule, exactly as it does over
    /// every other branch: the override is a statement of intent from whoever launched the process, and the
    /// location-derived rules exist only for the automatic path.
    func testResolveExplicitOverrideWinsOverDeployedDevelopmentProfileLocation() throws {
        let profileRoot = tempHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/feature-x-0123456789ab", isDirectory: true)
        let executablePath = profileRoot.appendingPathComponent("daemon/current/bin/spacesd", isDirectory: false).path
        let overridePath = tempHomeURL.appendingPathComponent("profiles/override/spaces.db").path

        let profile = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
            currentDirectoryPath: tempHomeURL.path, executablePath: executablePath, gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.source, .explicitDatabasePath)
        XCTAssertEqual(profile.databasePath, overridePath)
    }

    /// A deployed profile's directory name is only read as a worktree identity when it has the exact
    /// `<branch-slug>-<12 lowercase hex>` shape a derived name has. Anything else leaves BOTH halves absent:
    /// they are meaningful only as the pair naming the worktree the profile mirrors, and a half-parsed name
    /// would put a bogus label in the device's Bonjour service name.
    func testResolveDeployedDevelopmentProfileCarriesNoIdentityForANameThatIsNotDerived() throws {
        let names = [
            "demo",  // no trailing hash at all
            "feature-x-0123456789a",  // 11 hex digits, one short
            "feature-x-0123456789abc",  // 13 hex digits, one too many
            "feature-x-0123456789ag",  // right length, not hex
            "feature-x-0123456789AB",  // right length, uppercase hex is not what the producer emits
            "feature-x_0123456789ab",  // right length, separator is not a hyphen
            "0123456789ab",  // the hash alone, with no slug and no separator
            "-0123456789ab",  // a separator with an empty slug
        ]

        for name in names {
            let profileRoot = tempHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/\(name)", isDirectory: true)
            let profile = try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
                executablePath: profileRoot.appendingPathComponent("daemon/current/bin/spaces", isDirectory: false).path,
                gitProbe: StubGitProfileProbe(context: nil))

            XCTAssertEqual(profile.source, .deployedDevelopmentProfile, "'\(name)' is still a deployed profile, whatever its name says.")
            XCTAssertNil(profile.branchSlug, "'\(name)' is not a derived profile name, so it carries no branch slug.")
            XCTAssertNil(profile.worktreeHash, "'\(name)' is not a derived profile name, so it carries no worktree hash.")
        }
    }

    /// The layout is matched as a run of whole path components, so a binary that merely lives *near* the
    /// development-profiles tree is not claimed by it. Each of these would resolve to a profile root that
    /// does not exist, and the deployed daemon would then serve a database nobody deployed.
    func testDeployedDevelopmentProfileRootRejectsPathsThatOnlyResembleTheLayout() {
        let nonMatchingPaths = [
            "/Users/tester/.spaces-devil/profiles/spaces/feature-x/daemon/current/bin/spaces",
            "/Users/tester/.spaces-dev/profiles/other/feature-x/daemon/current/bin/spaces",
            "/Users/tester/.spaces-dev/spaces/profiles/feature-x/daemon/current/bin/spaces", "/Users/tester/.spaces/bin/spaces",
            "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
        ]

        for path in nonMatchingPaths {
            XCTAssertNil(SpacesProfile.deployedDevelopmentProfileRoot(executablePath: path), "\(path) does not live inside a deployed profile root.")
        }
    }

    /// The executable has to sit strictly inside a profile root for the root to own it. A path that stops at
    /// the root itself — or above it — names no executable, so there is no deployment to infer.
    func testDeployedDevelopmentProfileRootRequiresAnExecutableBelowTheProfileRoot() {
        XCTAssertNil(SpacesProfile.deployedDevelopmentProfileRoot(executablePath: "/Users/tester/.spaces-dev/profiles/spaces/feature-x"))
        XCTAssertNil(SpacesProfile.deployedDevelopmentProfileRoot(executablePath: "/Users/tester/.spaces-dev/profiles/spaces"))
        XCTAssertEqual(
            SpacesProfile.deployedDevelopmentProfileRoot(executablePath: "/Users/tester/.spaces-dev/profiles/spaces/feature-x/spacesd")?.path,
            SpacesProfile.canonicalPath("/Users/tester/.spaces-dev/profiles/spaces/feature-x"), "One component below the root is already inside it.")
    }

    /// With a nested `.spaces-dev/profiles/spaces` tree the OUTERMOST match is the profile: the outer
    /// sequence is what a deployment installed into, and the inner one is content that ended up sitting
    /// inside it. Choosing the inner match would serve a database inside another profile's root.
    func testDeployedDevelopmentProfileRootPrefersTheOutermostMatch() {
        let nestedPath =
            "/Users/tester/.spaces-dev/profiles/spaces/outer-0123456789ab/.spaces-dev/profiles/spaces/inner-abcdef012345/daemon/current/bin/spaces"

        XCTAssertEqual(
            SpacesProfile.deployedDevelopmentProfileRoot(executablePath: nestedPath)?.path,
            SpacesProfile.canonicalPath("/Users/tester/.spaces-dev/profiles/spaces/outer-0123456789ab"))
    }

    func testSameBranchDifferentWorktreesResolveDifferentProfiles() throws {
        let repoRoot = try makeFakeRepoRoot()
        let branchName = "feature/shared"
        let executablePath = repoRoot.appendingPathComponent("apps/macos/.build/debug/SpacesApp").path

        let first = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path, executablePath: executablePath,
            gitProbe: StubGitProfileProbe(context: .init(worktreeRoot: tempHomeURL.appendingPathComponent("worktree-a").path, branchName: branchName))
        )

        let second = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path, executablePath: executablePath,
            gitProbe: StubGitProfileProbe(context: .init(worktreeRoot: tempHomeURL.appendingPathComponent("worktree-b").path, branchName: branchName))
        )

        XCTAssertNotEqual(first.rootDirectory, second.rootDirectory)
        XCTAssertNotEqual(first.ipcNotificationObject, second.ipcNotificationObject)
    }

    func testRuntimeOverrideWinsOverDerivedProfileRuntime() throws {
        let runtimeOverride = tempHomeURL.appendingPathComponent("runtime-override").path
        let overridePath = tempHomeURL.appendingPathComponent("profile/spaces.db").path

        let profile = try SpacesProfile.resolve(
            environment: [
                SpacesProfile.databasePathEnvironmentVariable: overridePath, SpacesProfile.runtimeDirectoryEnvironmentVariable: runtimeOverride,
            ], homeDirectoryURL: tempHomeURL, currentDirectoryPath: tempHomeURL.path,
            executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp", gitProbe: StubGitProfileProbe(context: nil))

        XCTAssertEqual(profile.runtimeDirectory, runtimeOverride)
    }

    func testIPCObjectIsStableForSameProfileRootAndDistinctAcrossProfiles() {
        let first = SpacesProfile.ipcObject(profileRoot: "/tmp/spaces-profile-a")
        let second = SpacesProfile.ipcObject(profileRoot: "/tmp/spaces-profile-a")
        let third = SpacesProfile.ipcObject(profileRoot: "/tmp/spaces-profile-b")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, third)
    }

    func testCurrentProfileReadsLiveProcessOverridesAfterCacheWarmup() throws {
        let initialDatabasePath = tempHomeURL.appendingPathComponent("profiles/cache-warmup/spaces.db").path
        let initialRuntimePath = tempHomeURL.appendingPathComponent("profiles/cache-warmup/runtime").path
        let databasePath = tempHomeURL.appendingPathComponent("profiles/live-env/spaces.db").path
        let runtimePath = tempHomeURL.appendingPathComponent("profiles/live-env/runtime-override").path
        let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
        let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
        SpacesProfile.resetCacheForTesting()
        defer {
            if let originalDatabasePath {
                setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
            } else {
                unsetenv(SpacesProfile.databasePathEnvironmentVariable)
            }
            if let originalRuntimePath {
                setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimePath, 1)
            } else {
                unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            }
            SpacesProfile.resetCacheForTesting()
        }

        setenv(SpacesProfile.databasePathEnvironmentVariable, initialDatabasePath, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, initialRuntimePath, 1)
        _ = try SpacesProfile.current()

        setenv(SpacesProfile.databasePathEnvironmentVariable, databasePath, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, runtimePath, 1)

        let profile = try SpacesProfile.current()
        let databaseLocatorPath = try DatabaseLocator.defaultPath()
        let sessionPaths = try TerminalSessionPaths.forSession(id: "session-live-env")

        XCTAssertEqual(profile.source, .explicitDatabasePath)
        XCTAssertEqual(profile.databasePath, databasePath)
        XCTAssertEqual(profile.runtimeDirectory, runtimePath)
        XCTAssertNotEqual(profile.databasePath, initialDatabasePath)
        XCTAssertEqual(databaseLocatorPath, databasePath)
        XCTAssertTrue(sessionPaths.rootDirectory.hasPrefix(runtimePath + "/terminal/sessions/"))
    }

    /// `HOME` decides where every non-explicit profile's root lives, so it is one of the inputs the
    /// cached profile is keyed on. A cache that missed a `HOME` change would keep handing out paths
    /// under the previous home for the rest of the process's life.
    func testCurrentProfileFollowsHomeChangeAfterCacheWarmup() throws {
        _ = installHermeticGitEnvironment
        let firstHome = tempHomeURL.appendingPathComponent("home-a", isDirectory: true)
        let secondHome = tempHomeURL.appendingPathComponent("home-b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondHome, withIntermediateDirectories: true)

        try withEnvironmentValues([
            SpacesProfile.databasePathEnvironmentVariable: nil, SpacesProfile.runtimeDirectoryEnvironmentVariable: nil, "HOME": firstHome.path,
        ]) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            let warmed = try SpacesProfile.current()
            XCTAssertTrue(warmed.rootDirectory.hasPrefix(firstHome.path), "Expected \(warmed.rootDirectory) under \(firstHome.path).")

            setenv("HOME", secondHome.path, 1)
            let updated = try SpacesProfile.current()
            XCTAssertTrue(updated.rootDirectory.hasPrefix(secondHome.path), "Expected \(updated.rootDirectory) under \(secondHome.path).")
            XCTAssertEqual(try DatabaseLocator.defaultPath(), updated.databasePath)
        }
    }

    func testProfileAppOwnerLeaseRejectsDuplicateLaunches() throws {
        let profile = try explicitProfile(named: "duplicate")
        let first = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)
        guard case .acquired(let lease) = first else { return XCTFail("Expected first owner lease to be acquired.") }
        defer { lease.release() }

        let second = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)
        guard case .busy(let owner) = second else { return XCTFail("Expected duplicate profile lease to be busy.") }
        XCTAssertEqual(owner.pid, lease.owner.pid)
        XCTAssertEqual(owner.profileRoot, profile.rootDirectory)
    }

    func testProfileAppOwnerLeaseRecoversStaleOwner() throws {
        let profile = try explicitProfile(named: "stale")
        let leaseDirectory = URL(fileURLWithPath: profile.rootDirectory).appendingPathComponent("leases/app-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: leaseDirectory, withIntermediateDirectories: true)
        let staleOwner = SpacesProcessLeaseOwner(
            pid: -1, executablePath: "/tmp/stale/SpacesApp", profileRoot: profile.rootDirectory, token: "stale-token",
            acquiredAt: "2026-05-17T00:00:00Z")
        let data = try JSONEncoder().encode(staleOwner)
        try data.write(to: leaseDirectory.appendingPathComponent("owner.json"), options: .atomic)

        let result = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)
        guard case .acquired(let lease) = result else { return XCTFail("Expected stale owner to be replaced.") }
        defer { lease.release() }
        XCTAssertEqual(lease.owner.profileRoot, profile.rootDirectory)
        XCTAssertNotEqual(lease.owner.token, staleOwner.token)
    }

    func testDesktopControlLeaseAllowsSingleOwnerAcrossProfiles() throws {
        let firstProfile = try explicitProfile(named: "desktop-a")
        let secondProfile = try explicitProfile(named: "desktop-b")

        let first = try SpacesLeaseCoordinator.acquireDesktopControlLease(profile: firstProfile, homeDirectoryURL: tempHomeURL)
        guard case .acquired(let firstLease) = first else { return XCTFail("Expected first desktop lease acquisition.") }
        defer { firstLease.release() }

        let second = try SpacesLeaseCoordinator.acquireDesktopControlLease(profile: secondProfile, homeDirectoryURL: tempHomeURL)
        guard case .busy(let owner) = second else { return XCTFail("Expected second desktop lease to be busy.") }
        XCTAssertEqual(owner.pid, firstLease.owner.pid)
        XCTAssertEqual(owner.profileRoot, firstProfile.rootDirectory)
    }

    func testProfileAppOwnerLeaseWaitsForOwnerMetadataBeforeDeclaringStale() throws {
        let profile = try explicitProfile(named: "pending-owner")
        let leaseDirectory = URL(fileURLWithPath: profile.rootDirectory).appendingPathComponent("leases/app-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: leaseDirectory, withIntermediateDirectories: true)
        let executablePath = try XCTUnwrap(SpacesProfile.currentExecutablePath(currentDirectoryPath: FileManager.default.currentDirectoryPath))
        let expectedOwner = SpacesProcessLeaseOwner(
            pid: getpid(), executablePath: executablePath, profileRoot: profile.rootDirectory, token: "pending-owner-token",
            acquiredAt: "2026-05-18T00:00:00Z")
        let writerFinished = expectation(description: "lease metadata written")
        let writerError = LockedValueBox<Error>()
        Thread {
            do {
                Thread.sleep(forTimeInterval: 0.1)
                let data = try JSONEncoder().encode(expectedOwner)
                try data.write(to: leaseDirectory.appendingPathComponent("owner.json"), options: .atomic)
            } catch { writerError.set(error) }
            writerFinished.fulfill()
        }.start()

        let result = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)

        wait(for: [writerFinished], timeout: 2)

        XCTAssertNil(writerError.value)
        guard case .busy(let owner) = result else { return XCTFail("Expected pending owner metadata to resolve as busy.") }
        XCTAssertEqual(owner, expectedOwner)
    }

    func testDesktopControlLeaseDirectoryIgnoresHomeEnvironmentOverrideByDefault() throws {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", tempHomeURL.path, 1)
        defer { if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") } }

        let accountHomePath = try XCTUnwrap(currentUserAccountHomePath())
        let leaseDirectory = try SpacesLeaseCoordinator.desktopControlLeaseDirectory()

        XCTAssertEqual(leaseDirectory, "\(accountHomePath)/.spaces/leases/desktop-control")
        XCTAssertNotEqual(leaseDirectory, "\(tempHomeURL!.path)/.spaces/leases/desktop-control")
    }

    func testProfileAppOwnerLeaseRecoversWhenPIDIsReusedByDifferentExecutable() throws {
        let profile = try explicitProfile(named: "mismatched-owner")
        let leaseDirectory = URL(fileURLWithPath: profile.rootDirectory).appendingPathComponent("leases/app-owner", isDirectory: true)
        try FileManager.default.createDirectory(at: leaseDirectory, withIntermediateDirectories: true)
        let staleOwner = SpacesProcessLeaseOwner(
            pid: getpid(), executablePath: "/tmp/not-the-current-process", profileRoot: profile.rootDirectory, token: "stale-token",
            acquiredAt: "2026-05-17T00:00:00Z")
        let data = try JSONEncoder().encode(staleOwner)
        try data.write(to: leaseDirectory.appendingPathComponent("owner.json"), options: .atomic)

        let result = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)
        guard case .acquired(let lease) = result else { return XCTFail("Expected mismatched owner to be replaced.") }
        defer { lease.release() }
        XCTAssertEqual(lease.owner.profileRoot, profile.rootDirectory)
        XCTAssertNotEqual(lease.owner.token, staleOwner.token)
    }

    func testResolveThrowsForRepoBuiltBinaryWhenGitProbeThrows() throws {
        let repoRoot = try makeFakeRepoRoot()
        let executablePath = repoRoot.appendingPathComponent("apps/macos/.build/arm64-apple-macosx/debug/spacesd").path
        let probeError = NSError(domain: "SpacesGitProfileProbe", code: 128, userInfo: [NSLocalizedDescriptionKey: "fatal: not a git repository"])

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path, executablePath: executablePath,
                gitProbe: StubGitProfileProbe(result: .failure(probeError)))
        ) { error in
            guard case SpacesProfileResolutionError.repoBuiltGitProbeFailed(let reportedExecutable, let reportedRepoRoot, _) = error else {
                return XCTFail("Expected repoBuiltGitProbeFailed, got \(error).")
            }
            XCTAssertEqual(reportedExecutable, executablePath)
            XCTAssertEqual(reportedRepoRoot, repoRoot.path)
            let message = String(describing: error)
            XCTAssertTrue(message.contains(executablePath), "Error should name the executable path: \(message)")
            XCTAssertTrue(message.contains(repoRoot.path), "Error should name the repo root: \(message)")
            XCTAssertTrue(message.contains("fatal: not a git repository"), "Error should carry the underlying git failure: \(message)")
            XCTAssertTrue(message.contains("~/.spaces"), "Error should say it refuses the installed profile: \(message)")
            // The app's top-level launch catch prints `localizedDescription`; it must carry the same
            // diagnostics, not the generic NSError stub for a non-LocalizedError.
            XCTAssertEqual(error.localizedDescription, message, "localizedDescription should match the full diagnostic message")
        }
    }

    func testResolveThrowsForRepoBuiltBinaryWhenGitProbeReturnsNil() throws {
        let repoRoot = try makeFakeRepoRoot()
        let executablePath = repoRoot.appendingPathComponent("apps/macos/.build/arm64-apple-macosx/debug/spacesd").path

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path, executablePath: executablePath,
                gitProbe: StubGitProfileProbe(result: .success(nil)))
        ) { error in
            guard case SpacesProfileResolutionError.repoBuiltGitProbeFailed = error else {
                return XCTFail("Expected repoBuiltGitProbeFailed, got \(error).")
            }
        }
    }

    func testResolveDevelopmentWorktreeFromArchSpecificBuildPath() throws {
        let repoRoot = try makeFakeRepoRoot()
        let executablePath = repoRoot.appendingPathComponent("apps/macos/.build/arm64-apple-macosx/debug/spacesd").path
        let worktreeRoot = tempHomeURL.appendingPathComponent("worktree").path
        let context = SpacesDevelopmentContext(worktreeRoot: worktreeRoot, branchName: "feature/x")

        let profile = try SpacesProfile.resolve(
            environment: [:], homeDirectoryURL: tempHomeURL, currentDirectoryPath: repoRoot.path, executablePath: executablePath,
            gitProbe: StubGitProfileProbe(result: .success(context)))

        XCTAssertEqual(profile.source, .developmentWorktree)
    }

    func testResolveExplicitOverrideWinsForRepoBuiltBinaryEvenWhenGitProbeThrows() throws {
        let repoRoot = try makeFakeRepoRoot()
        let executablePath = repoRoot.appendingPathComponent("apps/macos/.build/arm64-apple-macosx/debug/spacesd").path
        let overridePath = tempHomeURL.appendingPathComponent("profiles/custom/spaces.db").path
        let probeError = NSError(domain: "SpacesGitProfileProbe", code: 128, userInfo: [NSLocalizedDescriptionKey: "boom"])

        let profile = try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
            currentDirectoryPath: repoRoot.path, executablePath: executablePath, gitProbe: StubGitProfileProbe(result: .failure(probeError)))

        XCTAssertEqual(profile.source, .explicitDatabasePath)
        XCTAssertEqual(profile.databasePath, overridePath)
    }

    private func explicitProfile(named name: String) throws -> SpacesProfile {
        let databasePath = tempHomeURL.appendingPathComponent("profiles/\(name)/spaces.db").path
        return try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: databasePath], homeDirectoryURL: tempHomeURL,
            currentDirectoryPath: tempHomeURL.path, executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
            gitProbe: StubGitProfileProbe(context: nil))
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
    let result: Result<SpacesDevelopmentContext?, Error>

    init(result: Result<SpacesDevelopmentContext?, Error>) { self.result = result }
    init(context: SpacesDevelopmentContext?) { self.result = .success(context) }

    func resolveDevelopmentContext(repoRootPath _: String) throws -> SpacesDevelopmentContext? { try result.get() }
}

private final class LockedValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func currentUserAccountHomePath() -> String? {
    let uid = getuid()
    let rawSize = sysconf(_SC_GETPW_R_SIZE_MAX)
    let bufferSize = rawSize > 0 ? Int(rawSize) : 16_384
    var buffer = [CChar](repeating: 0, count: bufferSize)
    var record = passwd()
    var result: UnsafeMutablePointer<passwd>?
    let status = getpwuid_r(uid, &record, &buffer, buffer.count, &result)
    guard status == 0, let entry = result else { return nil }
    return String(cString: entry.pointee.pw_dir)
}
