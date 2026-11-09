import Foundation
import XCTest
import spacesterminalcore

extension XCTestCase {
    /// Binds the profile environment to a fresh throwaway profile for the rest of this test, restoring the
    /// previous values in a teardown block.
    ///
    /// Terminal cores persist through the active profile rather than through the `TerminalSessionPaths`
    /// they are handed, and their serial persistence queue can still be draining after the test method
    /// returns. Binding for the whole test — teardown included — is what keeps that late work out of the
    /// developer's profile.
    func useIsolatedSpacesProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        let originalValues = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        // The profile root is left in place rather than deleted: the same late persistence work this
        // binding exists to contain would otherwise race a teardown that pulled the directory out from
        // under it. It is a temporary directory, so the system reclaims it.
        addTeardownBlock { for (name, value) in originalValues { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db", isDirectory: false).path, 1)
        setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, root.appendingPathComponent("runtime", isDirectory: true).path, 1)
    }
}

/// An empty `HOME` for the login shell a `HostManagedPTYTerminalSessionDriver` spawns, so its startup files
/// come from an empty directory instead of the developer's dotfiles (issue #935). Passed to the driver as
/// `testChildEnvironment`, which scopes it to the child; the test process's own `HOME` is untouched.
/// Created once per test process and left in the temporary directory, which the system reclaims.
enum IsolatedLoginProfile {
    static let environment: [(key: String, value: String)] = [("HOME", homeDirectory.path)]

    private static let homeDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-login-profile-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()
}
