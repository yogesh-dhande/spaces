import Testing

@testable import gui

struct UpdateCheckerTests {
    private let checker = UpdateChecker()

    // Tests newer major version by comparing a larger major number and asserting it is treated as newer.
    @Test func newerMajorVersion() {
        #expect(checker.isNewerVersion("2.0.0", than: "1.0.0"))
    }

    // Tests newer minor version by keeping major equal and asserting a larger minor number wins.
    @Test func newerMinorVersion() {
        #expect(checker.isNewerVersion("0.2.0", than: "0.1.0"))
    }

    // Tests newer patch version by keeping major/minor equal and asserting patch increment is newer.
    @Test func newerPatchVersion() {
        #expect(checker.isNewerVersion("0.1.1", than: "0.1.0"))
    }

    // Tests same version by comparing identical version strings and asserting no upgrade is detected.
    @Test func sameVersion() {
        #expect(!checker.isNewerVersion("0.1.0", than: "0.1.0"))
    }

    // Tests older version by comparing a smaller version and asserting it is not considered newer.
    @Test func olderVersion() {
        #expect(!checker.isNewerVersion("0.0.9", than: "0.1.0"))
    }

    // Tests different length versions by asserting extra trailing segments are compared deterministically.
    @Test func differentLengthVersions() {
        #expect(checker.isNewerVersion("1.0.0.1", than: "1.0.0"))
        #expect(!checker.isNewerVersion("1.0", than: "1.0.0"))
    }
}
