import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalLostShellSeparatorTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-15 21:24:00 UTC
    private let lastOutput = Date(timeIntervalSince1970: 1_792_099_440)

    func testHostBootedAfterTheLastOutputReadsAsARestartOfThatPlatform() {
        let booted = lastOutput.addingTimeInterval(60)

        XCTAssertEqual(TerminalLostShellSeparator.cause(lastOutputAt: lastOutput, hostBootedAt: booted, platform: .mac), .hostRestarted(.mac))
        XCTAssertEqual(TerminalLostShellSeparator.cause(lastOutputAt: lastOutput, hostBootedAt: booted, platform: .linux), .hostRestarted(.linux))
    }

    func testHostBootedBeforeTheLastOutputMeansOnlySpacesStopped() {
        let booted = lastOutput.addingTimeInterval(-3600)

        XCTAssertEqual(TerminalLostShellSeparator.cause(lastOutputAt: lastOutput, hostBootedAt: booted, platform: .mac), .spacesStoppedUnexpectedly)
    }

    func testUnknownBootTimeClaimsNoRestart() {
        XCTAssertEqual(TerminalLostShellSeparator.cause(lastOutputAt: lastOutput, hostBootedAt: nil, platform: .linux), .spacesStoppedUnexpectedly)
    }

    func testTextNamesTheCauseAndTheLastOutputTime() {
        XCTAssertEqual(
            TerminalLostShellSeparator.text(cause: .hostRestarted(.mac), lastOutputAt: lastOutput, timeZone: utc),
            "Shell ended when the Mac restarted \u{00B7} Oct 15, 9:24 PM \u{00B7} new shell below")
        XCTAssertEqual(
            TerminalLostShellSeparator.text(cause: .hostRestarted(.linux), lastOutputAt: lastOutput, timeZone: utc),
            "Shell ended when the computer restarted \u{00B7} Oct 15, 9:24 PM \u{00B7} new shell below")
        XCTAssertEqual(
            TerminalLostShellSeparator.text(cause: .spacesStoppedUnexpectedly, lastOutputAt: lastOutput, timeZone: utc),
            "Shell ended when Spaces stopped unexpectedly \u{00B7} Oct 15, 9:24 PM \u{00B7} new shell below")
    }

    func testTimeIsFormattedInTheGivenZoneIndependentOfTheMachineLocale() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        XCTAssertTrue(
            TerminalLostShellSeparator.text(cause: .spacesStoppedUnexpectedly, lastOutputAt: lastOutput, timeZone: tokyo).contains("Oct 16, 6:24 AM"))
    }

    func testProcStatBootTimeIsTheBtimeLine() {
        let procStat = "cpu  1 2 3\nintr 5\nbtime 1792000000\nprocesses 99\n"

        XCTAssertEqual(HostBootTime.bootTime(procStat: procStat), Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertNil(HostBootTime.bootTime(procStat: "cpu 1 2 3\n"))
    }
}
