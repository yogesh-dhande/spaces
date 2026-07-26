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
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let databasePath) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertEqual(databasePath, accountHomeURL.appendingPathComponent(".spaces/spaces.db").path)
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

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [:], homeDirectoryURL: accountHomeURL, currentDirectoryPath: repoRoot.path,
                executablePath: repoRoot.appendingPathComponent("apps/macos/.build/debug/spacesd").path,
                gitProbe: StubGitProfileProbe(context: context))
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let databasePath) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertTrue(
                databasePath.hasPrefix(accountHomeURL.appendingPathComponent(".spaces-dev/profiles").path),
                "Expected the refused path to be a development profile, got \(databasePath).")
        }
    }

    /// An explicit `SPACES_DB_PATH` is how tests isolate, so it is not exempt: a shell bound to a live dev
    /// profile (what `spacese2e profile-show --shell` exports) is the most likely way a test run reaches
    /// one, and the override branch runs before any other.
    func testResolveRefusesExplicitOverrideInsideDevelopmentProfileRootForTestHost() throws {
        let accountHomeURL = URL(fileURLWithPath: try XCTUnwrap(currentUserAccountHomePath()), isDirectory: true)
        let overridePath = accountHomeURL.appendingPathComponent(".spaces-dev/profiles/spaces/main-abc123/spaces.db").path

        XCTAssertThrowsError(
            try SpacesProfile.resolve(
                environment: [SpacesProfile.databasePathEnvironmentVariable: overridePath], homeDirectoryURL: tempHomeURL,
                currentDirectoryPath: tempHomeURL.path, executablePath: "/Applications/Spaces.app/Contents/MacOS/SpacesApp",
                gitProbe: StubGitProfileProbe(context: nil))
        ) { error in
            guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile(let databasePath) = error else {
                return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
            }
            XCTAssertEqual(databasePath, overridePath)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: URL(fileURLWithPath: overridePath).deletingLastPathComponent().path),
            "A refused resolution must not have created the profile directory.")
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
