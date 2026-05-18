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
    let context: SpacesDevelopmentContext?
    func resolveDevelopmentContext(repoRootPath _: String) throws -> SpacesDevelopmentContext? { context }
}
