import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalOverviewSignalTests: XCTestCase {
    /// The device-overview stream server reacts to terminal runtime/title/exit
    /// changes by observing `TerminalOverviewSignal.name`, while the terminal
    /// session hosts announce those changes via `TerminalOverviewSignal.post()`.
    /// Both sides must rendezvous on the same name, so a producer post must reach
    /// an in-process observer registered on that name.
    func testPostDeliversToInProcessObserver() {
        let received = expectation(description: "overview signal delivered")
        let observer = NotificationCenter.default.addObserver(forName: TerminalOverviewSignal.name, object: nil, queue: nil) { _ in received.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        TerminalOverviewSignal.post()

        wait(for: [received], timeout: 1)
    }

    /// Issue #322 follow-up: `post`'s cross-process half used to swallow a test-host refusal with
    /// `try?`, indistinguishable from an ordinary "no profile" resolution failure. It cannot trap on the
    /// refusal instead (see `SpacesProfile.currentOrNilLoggingRefusal`'s doc comment — this fires from a
    /// detached engine-actor task on every runtime-state change, so trapping would abort the whole merged
    /// test process over a resolution failure that may not even belong to the test that is executing).
    /// This proves the wiring survives a refusal end to end: the in-process post — which the device
    /// overview stream server actually observes same-process — still reaches its observer, on macOS
    /// where the swallowed call lived.
    #if os(macOS)
        func testPostStillDeliversToInProcessObserverWhenTheCrossProcessHalfIsRefused() throws {
            let accountHomePath = try XCTUnwrap(SpacesProfile.accountHomeDirectoryPath())
            let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
            let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
            let originalHome = ProcessInfo.processInfo.environment["HOME"]
            unsetenv(SpacesProfile.databasePathEnvironmentVariable)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            setenv("HOME", accountHomePath, 1)
            SpacesProfile.resetCacheForTesting()
            defer {
                restoreEnvironmentValue(originalDatabasePath, name: SpacesProfile.databasePathEnvironmentVariable)
                restoreEnvironmentValue(originalRuntimePath, name: SpacesProfile.runtimeDirectoryEnvironmentVariable)
                restoreEnvironmentValue(originalHome, name: "HOME")
                SpacesProfile.resetCacheForTesting()
            }

            let received = expectation(description: "overview signal delivered despite a refused cross-process post")
            let observer = NotificationCenter.default.addObserver(forName: TerminalOverviewSignal.name, object: nil, queue: nil) { _ in
                received.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            TerminalOverviewSignal.post()

            wait(for: [received], timeout: 1)
        }
    #endif

    private func restoreEnvironmentValue(_ value: String?, name: String) { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
}
