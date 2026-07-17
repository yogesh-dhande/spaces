import Foundation
import XCTest
import spacesterminalcore

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
}
