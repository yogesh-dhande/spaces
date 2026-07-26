import Foundation

/// Whether this process is a test host. Used by code that must behave differently when it cannot
/// be allowed to touch real user state — most importantly profile resolution, which refuses the
/// installed profile in a test process.
public enum SpacesTestHost {
    /// Checks every way a test bundle announces itself: Xcode sets the configuration-file variable,
    /// SwiftPM passes the `.xctest` bundle on the command line, and once the bundle is loaded it is
    /// in `Bundle.allBundles`. Any one of them is conclusive; they are all checked because which one
    /// is available depends on the runner and on how early in process startup the question is asked.
    public static func isRunningUnderXCTest() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if canImport(ObjectiveC)
            if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        if CommandLine.arguments.contains(where: { $0.hasSuffix(".xctest") }) { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }
}
