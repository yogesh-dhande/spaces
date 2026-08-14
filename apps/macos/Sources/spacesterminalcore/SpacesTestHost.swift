import Foundation

/// Whether this process is a test host. Used by code that must behave differently when it cannot
/// be allowed to touch real user state — most importantly profile resolution, which refuses any live
/// user profile in a test process.
public enum SpacesTestHost {
    /// Checks every way a test host announces itself, because no single signal covers every lane. Each
    /// of these was measured on the lane it covers rather than assumed:
    ///
    /// - Xcode sets `XCTestConfigurationFilePath`.
    /// - macOS `swift test` runs both of its lanes out of the toolchain — `xctest` for XCTest,
    ///   `swiftpm-testing-helper` for Swift Testing — with no `.xctest` path among the arguments, so the
    ///   linked-in `XCTestCase` class is the only signal there. Removing it silently drops the guard for
    ///   every macOS Swift Testing suite; `SpacesTestHostDetectionTests` fails if it goes.
    /// - Linux has no Objective-C runtime, so that check is compiled out. `swift test` there execs the
    ///   test binary directly and its `argv[0]` is `<Package>PackageTests.xctest`, which is the only
    ///   signal on that platform — hence `executableIsTestBundle`, and hence that suite runs in the
    ///   Linux lane too.
    ///
    /// `Bundle.allBundles` is deliberately NOT consulted. On Linux (corelibs-foundation, Swift 6.2) it
    /// dereferences null inside `CFBundleGetAllBundles` and takes the process down with SIGSEGV, and it
    /// is every NON-test Linux process that reaches the end of this function — `spacesd` runs it on each
    /// profile resolution, so consulting it there is a daemon crash on startup. No lane needs it.
    public static func isRunningUnderXCTest() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        #if canImport(ObjectiveC)
            if NSClassFromString("XCTestCase") != nil { return true }
        #endif
        return executableIsTestBundle(arguments: CommandLine.arguments)
    }

    /// Whether the running executable — `argv[0]`, and only `argv[0]` — is a test bundle.
    ///
    /// Restricted to the executable on purpose. The rest of `argv` is data the executable was asked to
    /// operate on, and a Spaces command may legitimately name a test bundle in it: running
    /// `spaces terminal create --command 'xcrun xctest ./Foo.xctest'`, or tailing a path under a `.xctest`
    /// directory, must not make the CLI classify itself as a test host and then refuse the user's own
    /// live profile. Empty arguments answer `false` rather than trapping.
    static func executableIsTestBundle(arguments: [String]) -> Bool { arguments.first?.hasSuffix(".xctest") ?? false }
}
