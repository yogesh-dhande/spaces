import Foundation
import XCTest

@testable import spacesterminalcore

final class DaemonSelfUpdateFeedTests: XCTestCase {
    func testEachChannelHasItsOwnFeedURL() {
        XCTAssertEqual(DaemonSelfUpdateFeed.url(for: .stable).absoluteString, "https://usespaces.dev/releases/linux-latest.json")
        XCTAssertEqual(DaemonSelfUpdateFeed.url(for: .prerelease).absoluteString, "https://usespaces.dev/releases/prerelease/linux-latest.json")
    }

    func testParsesTheVersionFromAFeedBody() {
        XCTAssertEqual(DaemonSelfUpdateFeed.parseVersion(from: Data(#"{"version":"0.24.0"}"#.utf8)), "0.24.0")
        XCTAssertEqual(DaemonSelfUpdateFeed.parseVersion(from: Data("{\"version\": \"0.24.1\"}\n".utf8)), "0.24.1")
    }

    func testRejectsBodiesThatAreNotAFeed() {
        for body in ["", "<html>captive portal</html>", #"{"version":""}"#, #"{"version":42}"#, #"{"other":"1.0.0"}"#, #"{"version":"v0.24.0"}"#,
            #"{"version":"0.24."}"#, "[]"]
        {
            XCTAssertNil(DaemonSelfUpdateFeed.parseVersion(from: Data(body.utf8)), body)
        }
    }

    func testAvailableOnlyWhenTheFeedIsNewerThanTheRunningVersion() {
        XCTAssertEqual(DaemonSelfUpdateFeed.availableVersion(runningVersion: "0.23.0", feedVersion: "0.24.0"), "0.24.0")
        XCTAssertNil(DaemonSelfUpdateFeed.availableVersion(runningVersion: "0.24.0", feedVersion: "0.24.0"))
        XCTAssertNil(DaemonSelfUpdateFeed.availableVersion(runningVersion: "0.25.0", feedVersion: "0.24.0"))
    }

    func testDefaultChannelIsPrereleaseWhenRunningBuildIsNewerThanStable() {
        XCTAssertEqual(DaemonSelfUpdateFeed.defaultChannel(runningVersion: "0.24.0", stableFeedVersion: "0.23.0"), .prerelease)
    }

    func testDefaultChannelIsStableWhenRunningBuildIsStableOrBehind() {
        XCTAssertEqual(DaemonSelfUpdateFeed.defaultChannel(runningVersion: "0.23.0", stableFeedVersion: "0.23.0"), .stable)
        XCTAssertEqual(DaemonSelfUpdateFeed.defaultChannel(runningVersion: "0.22.0", stableFeedVersion: "0.23.0"), .stable)
    }

    func testDefaultChannelIsUndecidedUntilTheStableFeedIsKnown() {
        XCTAssertNil(DaemonSelfUpdateFeed.defaultChannel(runningVersion: "0.24.0", stableFeedVersion: nil))
    }

    func testInstallerIsFoundBesideTheRunningRelease() {
        let executable = URL(fileURLWithPath: "/home/u/.spaces/daemon/releases/0.23.0/bin/spacesd")

        XCTAssertEqual(
            DaemonSelfUpdateInstallLayout.installerURL(forExecutable: executable)?.path,
            "/home/u/.spaces/daemon/releases/0.23.0/spaces-install-linux.sh")
    }

    func testDevelopmentBuildHasNoInstaller() {
        XCTAssertNil(DaemonSelfUpdateInstallLayout.installerURL(forExecutable: URL(fileURLWithPath: "/work/spaces/apps/macos/.build/debug/spacesd")))
    }
}
