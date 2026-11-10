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
