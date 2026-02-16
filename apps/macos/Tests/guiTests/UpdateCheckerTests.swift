import Testing

@testable import gui

struct UpdateCheckerTests {
    private let checker = UpdateChecker()

    @Test func newerMajorVersion() {
        #expect(checker.isNewerVersion("2.0.0", than: "1.0.0"))
    }

    @Test func newerMinorVersion() {
        #expect(checker.isNewerVersion("0.2.0", than: "0.1.0"))
    }

    @Test func newerPatchVersion() {
        #expect(checker.isNewerVersion("0.1.1", than: "0.1.0"))
    }

    @Test func sameVersion() {
        #expect(!checker.isNewerVersion("0.1.0", than: "0.1.0"))
    }

    @Test func olderVersion() {
        #expect(!checker.isNewerVersion("0.0.9", than: "0.1.0"))
    }

    @Test func differentLengthVersions() {
        #expect(checker.isNewerVersion("1.0.0.1", than: "1.0.0"))
        #expect(!checker.isNewerVersion("1.0", than: "1.0.0"))
    }
}
