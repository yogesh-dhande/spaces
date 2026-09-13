import Foundation
import XCTest

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The account-home lookup reads the password database directly, so these exercise it against this machine's
/// own entry. A stubbed directory service would only assert the stub: what matters here is that the lookup
/// obeys `getpwuid_r`'s buffer contract as the real implementation states it.
///
/// This suite is XCTest, like its siblings in this directory. The growth logic is libc-generic and the
/// directory compiles whole on Linux, but the Linux lane runs only the Swift Testing suites named in
/// `run_linux_tests.sh`, so this coverage is the macOS lane's.
final class AccountHomeDirectoryLookupTests: XCTestCase {
    func testLookupGrowsPastABufferThePasswordDatabaseRejects() throws {
        // A single attempt with a one-byte buffer is what the lookup did before it grew one: establish that the
        // password database really does reject that size, so the growth below is the only reason it succeeds.
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var singleAttemptBuffer = [CChar](repeating: 0, count: 1)
        XCTAssertEqual(getpwuid_r(getuid(), &record, &singleAttemptBuffer, singleAttemptBuffer.count, &result), ERANGE)
        XCTAssertNil(result)

        let grownFromOneByte = try SpacesProfile.accountHomeDirectory(initialBufferSize: 1)

        XCTAssertFalse(grownFromOneByte.isEmpty)
        XCTAssertEqual(grownFromOneByte, try SpacesProfile.accountHomeDirectory())
    }

    func testFailureReasonsNameTheConditionThatFailed() {
        XCTAssertEqual(
            String(describing: SpacesAccountHomeLookupFailure.lookupFailed(uid: 501, status: ERANGE, bufferSize: 1_048_576)),
            "getpwuid_r for uid 501 failed: ERANGE, with a 1048576-byte record buffer")
        XCTAssertEqual(
            String(describing: SpacesAccountHomeLookupFailure.noEntryForAccount(uid: 501)), "the password database holds no entry for uid 501")
        XCTAssertEqual(
            String(describing: SpacesAccountHomeLookupFailure.emptyHomeDirectory(uid: 501)),
            "the password database entry for uid 501 names no home directory")
    }

    func testUnnamedStatusReportsItsNumberAndTheSystemDescription() {
        let reason = String(describing: SpacesAccountHomeLookupFailure.lookupFailed(uid: 501, status: EDOM, bufferSize: 4096))

        XCTAssertTrue(reason.hasPrefix("getpwuid_r for uid 501 failed: errno \(EDOM) ("), reason)
        XCTAssertTrue(reason.hasSuffix("), with a 4096-byte record buffer"), reason)
    }
}
