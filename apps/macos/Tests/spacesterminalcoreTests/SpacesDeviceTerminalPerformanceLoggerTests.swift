import Foundation
import Testing

@testable import spacesterminalcore

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// `SpacesDeviceTerminalPerformanceLogger` resolves its log path once, from the process's real environment,
/// the first time the enum is touched (see the doc comment on `resolvedLogPathAtLaunch`). That is a
/// deliberate trade against reading `ProcessInfo.processInfo.environment` per call, which materializes the
/// whole environment dictionary and once cost 70-80% of the serial terminal-engine queue's CPU while the
/// logger was disabled (#332).
///
/// A direct consequence is that setting the environment variable mid-process has no effect. This suite
/// proves that behavior observably: a disabled logger, once resolved, never reacts to `setenv` and never
/// writes a log line no matter how many times `emit` is subsequently called. If the pre-fix per-call
/// `ProcessInfo.processInfo.environment` default argument were restored, this would fail because the later
/// `setenv` would flip `isEnabled()` and `emit` would start writing to `logPath`.
@Suite(.serialized) struct SpacesDeviceTerminalPerformanceLoggerTests {
    @Test func loggerDoesNotReactToEnvironmentMutationAfterProcessStart() throws {
        // Touch the logger first so `resolvedLogPathAtLaunch` resolves against whatever the environment
        // was before this test mutates it. In practice this is already resolved by the time any test in
        // the process runs, since nothing exports this variable in the test environment.
        let initiallyEnabled = SpacesDeviceTerminalPerformanceLogger.isEnabled()
        #expect(!initiallyEnabled, "test assumes \(SpacesDeviceTerminalPerformanceLogger.environmentKey) is not set in the test environment")

        let logPath = NSTemporaryDirectory() + "spaces-perf-logger-test-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        setenv(SpacesDeviceTerminalPerformanceLogger.environmentKey, logPath, 1)
        defer { unsetenv(SpacesDeviceTerminalPerformanceLogger.environmentKey) }

        // A resolved-once logger must ignore this: isEnabled() should still read disabled...
        #expect(!SpacesDeviceTerminalPerformanceLogger.isEnabled())

        // ...and emitting, however many times, must never construct an event or write to the newly-set path.
        for index in 0..<1000 {
            SpacesDeviceTerminalPerformanceLogger.emit(
                .init(sessionID: "test-session", source: "test", name: "tick", count: index))
        }

        #expect(!FileManager.default.fileExists(atPath: logPath))
    }
}
