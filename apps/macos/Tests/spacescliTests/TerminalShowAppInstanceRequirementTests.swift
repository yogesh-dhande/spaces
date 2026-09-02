import Foundation
import XCTest
import spacesterminalcore
import workspacecore

@testable import spacescli

/// Covers `requireRunningAppInstance`, the helper `TerminalShowCommand` calls before firing its
/// fire-and-forget IPC notification: it should fail loudly when no Spaces app instance holds this
/// profile's app-owner lease, and stay silent when one does.
final class TerminalShowAppInstanceRequirementTests: XCTestCase {
    private var tempRootURL: URL!

    override func setUpWithError() throws {
        tempRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRootURL, FileManager.default.fileExists(atPath: tempRootURL.path) { try FileManager.default.removeItem(at: tempRootURL) }
        tempRootURL = nil
    }

    func testThrowsWhenNoAppInstanceHoldsTheProfileLease() throws {
        let profile = makeProfile(named: "no-owner")

        XCTAssertThrowsError(try requireRunningAppInstance(profile: profile)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else {
                return XCTFail("Expected WorkspaceError.invalidArgument, got \(error).")
            }
            XCTAssertTrue(message.contains("No Spaces app instance is running"), "Unexpected message: \(message)")
        }
    }

    func testSucceedsWhenAnAppInstanceHoldsTheProfileLease() throws {
        let profile = makeProfile(named: "live-owner")
        let acquisition = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)
        guard case .acquired(let lease) = acquisition else { return XCTFail("Expected the lease to be acquired for this test process.") }
        defer { lease.release() }

        XCTAssertNoThrow(try requireRunningAppInstance(profile: profile))
    }

    func testThrowsAgainAfterTheOwningInstanceReleasesItsLease() throws {
        let profile = makeProfile(named: "released-owner")
        let acquisition = try SpacesLeaseCoordinator.acquireProfileAppOwnerLease(profile: profile)
        guard case .acquired(let lease) = acquisition else { return XCTFail("Expected the lease to be acquired for this test process.") }
        lease.release()

        XCTAssertThrowsError(try requireRunningAppInstance(profile: profile))
    }

    private func makeProfile(named name: String) -> SpacesProfile {
        let rootDirectory = tempRootURL.appendingPathComponent(name, isDirectory: true).path
        return SpacesProfile(
            source: .explicitDatabasePath, databasePath: rootDirectory + "/spaces.db", rootDirectory: rootDirectory, isInstalledProfile: false,
            runtimeDirectory: rootDirectory + "/runtime", ipcNotificationObject: "com.spaces.test.\(name)", developmentContext: nil,
            branchSlug: nil, worktreeHash: nil)
    }
}
