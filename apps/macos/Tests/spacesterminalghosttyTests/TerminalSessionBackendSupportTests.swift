import Foundation
import XCTest
import spacesterminalcore

@testable import spacesterminalghostty

final class TerminalSessionBackendSupportTests: XCTestCase {
    func testGhosttyEmbeddedAvailabilityMatchesPlatformBuild() {
        #if os(Linux)
            XCTAssertTrue(TerminalSessionBackendSupport.isSupported(.ghosttyEmbedded, environment: [:], currentDirectoryPath: "/tmp/spaces-terminal"))
        #else
            XCTAssertFalse(
                TerminalSessionBackendSupport.isSupported(.ghosttyEmbedded, environment: [:], currentDirectoryPath: "/tmp/spaces-terminal"))
        #endif
    }
}
