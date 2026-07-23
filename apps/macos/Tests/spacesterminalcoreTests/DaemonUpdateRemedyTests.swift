import Foundation
import XCTest

@testable import spacesterminalcore

final class DaemonUpdateRemedyTests: XCTestCase {
    func testClientTooOldWithoutStagedUpdateNeedsClientUpdate() {
        let status = makeStatus(version: "0.1.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version + 1)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .updateClient)
    }

    func testClientTooOldWithStagedUpdateStillNeedsClientUpdate() {
        // A staged update on the device would only push the daemon further ahead of this client, so the
        // client-update check wins regardless of what is staged.
        let status = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version + 1)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .updateClient)
    }

    func testDaemonTooOldWithStagedUpdateAppliesStagedUpdate() {
        let status = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version - 1)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .applyStagedUpdate(installedVersion: "0.2.0"))
    }

    func testDaemonTooOldWithNoInstalledBuildNeedsInstallOnDevice() {
        let status = makeStatus(version: "0.1.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version - 1)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .installUpdateOnDevice)
    }

    func testDaemonTooOldWithInstalledBuildEqualToRunningNeedsInstallOnDevice() {
        let status = makeStatus(version: "0.1.0", installedVersion: "0.1.0", protocolVersion: SpacesWireProtocol.version - 1)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .installUpdateOnDevice)
    }

    func testDaemonTooOldWithOlderInstalledBuildNeedsInstallOnDevice() {
        // A downgrade sitting on disk is not something a restart should apply.
        let status = makeStatus(version: "0.2.0", installedVersion: "0.1.0", protocolVersion: SpacesWireProtocol.version - 1)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .installUpdateOnDevice)
    }

    func testCompatibleWithStagedUpdateAppliesStagedUpdate() {
        let status = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .applyStagedUpdate(installedVersion: "0.2.0"))
    }

    func testCompatibleWithNothingStagedNeedsNoAction() {
        let status = makeStatus(version: "0.1.0", installedVersion: nil, protocolVersion: SpacesWireProtocol.version)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .none)
    }

    func testLinuxDaemonWithStagedUpdateAppliesStagedUpdate() {
        // The remedy is OS-independent; only the copy a view renders for it differs.
        let status = makeStatus(version: "0.1.0", installedVersion: "0.2.0", protocolVersion: SpacesWireProtocol.version, operatingSystem: "Linux")
        XCTAssertTrue(status.isLinuxDaemon)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status), .applyStagedUpdate(installedVersion: "0.2.0"))
    }

    func testOffersDaemonUpdateActionOnlyForApplyStagedUpdate() {
        XCTAssertFalse(DaemonUpdateRemedy.none.offersDaemonUpdateAction)
        XCTAssertFalse(DaemonUpdateRemedy.updateClient.offersDaemonUpdateAction)
        XCTAssertTrue(DaemonUpdateRemedy.applyStagedUpdate(installedVersion: "0.2.0").offersDaemonUpdateAction)
        XCTAssertFalse(DaemonUpdateRemedy.installUpdateOnDevice.offersDaemonUpdateAction)
    }

    private func makeStatus(version: String, installedVersion: String?, protocolVersion: Int, operatingSystem: String = "macOS")
        -> TerminalServiceDaemonStatus
    {
        TerminalServiceDaemonStatus(
            version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0,
            protocolVersion: protocolVersion, operatingSystem: operatingSystem)
    }
}
