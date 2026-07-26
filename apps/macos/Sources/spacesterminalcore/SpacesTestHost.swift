import Foundation

/// Whether this process is a test host. Used by code that must behave differently when it cannot
/// be allowed to touch real user state — most importantly profile resolution, which refuses the
/// installed profile in a test process.
public enum SpacesTestHost {
    /// Checks every way a test bundle announces itself, because no single one covers every runner.
    /// Xcode sets the configuration-file variable; `swift test`'s XCTest lane passes the `.xctest`
    /// bundle on the command line and has it loaded in `Bundle.allBundles`.
    ///
    /// `swift test`'s Swift Testing lane exhibits NONE of those: it runs under
    /// `swiftpm-testing-helper` with no `.xctest` in either the arguments or `Bundle.allBundles`, so
    /// the linked-in `XCTestCase` class is the only signal left and is what makes profile resolution
    /// refuse the installed profile for that lane's suites. Removing that check would silently drop
    /// the guard for every Swift Testing suite; `SpacesTestHostDetectionTests` fails if it does.
    public static func isRunningUnderXCTest() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if canImport(ObjectiveC)
            if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        if CommandLine.arguments.contains(where: { $0.hasSuffix(".xctest") }) { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
}
