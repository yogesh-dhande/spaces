import Foundation

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
