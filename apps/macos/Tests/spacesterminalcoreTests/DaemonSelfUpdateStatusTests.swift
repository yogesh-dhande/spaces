import Foundation
import XCTest

@testable import spacesterminalcore

final class DaemonSelfUpdateStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> TerminalServiceDaemonStatus {
        try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: Data(json.utf8))
    }

    func testSelfUpdateRoundTripsThroughEncodeAndDecode() throws {
        let progress = DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: .downloading, receivedBytes: 12_400_000, totalBytes: 38_000_000)
        let status = TerminalServiceDaemonStatus(
            version: "0.23.0", installedVersion: "0.23.0", certificateFingerprint: nil, activeSessionCount: 0,
            selfUpdate: DaemonSelfUpdateStatus(channel: .prerelease, availableVersion: "0.24.0", progress: progress))

        let decoded = try JSONDecoder().decode(TerminalServiceDaemonStatus.self, from: try JSONEncoder().encode(status))

        XCTAssertEqual(decoded, status)
        XCTAssertEqual(decoded.selfUpdate?.progress, progress)
    }

    func testStatusWithoutSelfUpdateDecodesToNil() throws {
        let decoded = try decode(#"{"version":"1.2.3","installedVersion":null,"certificateFingerprint":null,"activeSessionCount":0}"#)

        XCTAssertNil(decoded.selfUpdate)
    }

    func testMalformedSelfUpdateDegradesToNilWithoutFailingTheStatus() throws {
        let decoded = try decode(
            #"{"version":"1.2.3","protocolVersion":67,"activeSessionCount":3,"selfUpdate":{"channel":"nightly","availableVersion":5}}"#)

        XCTAssertNil(decoded.selfUpdate)
        XCTAssertEqual(decoded.version, "1.2.3")
        XCTAssertEqual(decoded.protocolVersion, 67)
        XCTAssertEqual(decoded.activeSessionCount, 3)
    }

    func testCacheNotifiesOnlyWhenTheStoredStatusChanges() {
        final class Counter: @unchecked Sendable { var count = 0 }
        let counter = Counter()
        let cache = DaemonSelfUpdateStatusCache(onChange: { counter.count += 1 })
        let idle = DaemonSelfUpdateStatus(channel: .stable)
        let found = DaemonSelfUpdateStatus(channel: .stable, availableVersion: "0.24.0")

        cache.store(nil)
        XCTAssertEqual(counter.count, 0)
        cache.store(idle)
        XCTAssertEqual(counter.count, 1)
        cache.store(idle)
        XCTAssertEqual(counter.count, 1)
        cache.store(found)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(cache.current, found)
    }

    /// The run installs its build before handing off to it; that window is not a staged update for a
    /// client to apply, or the Mac fires a second handoff and swaps the update block for a staged one.
    func testABuildInstalledByAMovingSelfUpdateRunIsNotStaged() {
        func status(step: DaemonSelfUpdateProgress.Step?) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: "0.23.0", installedVersion: "0.24.0", certificateFingerprint: nil, activeSessionCount: 0,
                selfUpdate: DaemonSelfUpdateStatus(
                    channel: .stable, availableVersion: "0.24.0",
                    progress: step.map { DaemonSelfUpdateProgress(targetVersion: "0.24.0", step: $0, failureReason: $0 == .failed ? "x" : nil) }))
        }

        XCTAssertNil(status(step: .installing).stagedVersion)
        XCTAssertNil(status(step: .restarting).stagedVersion)
        XCTAssertEqual(DaemonUpdateRemedy.remedy(for: status(step: .installing)), .none)
        XCTAssertEqual(status(step: .failed).stagedVersion, "0.24.0")
        XCTAssertEqual(status(step: nil).stagedVersion, "0.24.0")
    }

    func testSelfUpdateWithUnknownProgressStepDegradesToNil() throws {
        let decoded = try decode(
            #"{"version":"1.2.3","selfUpdate":{"channel":"stable","progress":{"targetVersion":"1.3.0","step":"verifying"}}}"#)

        XCTAssertNil(decoded.selfUpdate)
    }
}
