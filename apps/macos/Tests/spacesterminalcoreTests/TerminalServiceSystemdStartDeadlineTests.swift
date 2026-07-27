import Foundation
import Testing

@testable import spacesterminalcore

#if os(Linux)
    /// `ensureRunning(timeout:)` promises the caller an answer within `timeout`, and on Linux that window
    /// has to cover both asking user systemd to start the profile's unit and waiting for the daemon's
    /// socket. This suite pins the bound that makes the promise hold: `sendProfileCommand` passes
    /// `min(timeout, 5)` precisely so a device whose user systemd never answers cannot stall a command.
    ///
    /// Deliberately a Swift Testing suite, and Linux-only: the helper exists only in the Linux half of
    /// `TerminalService`, and an XCTest suite deadlocks the Linux runner (see
    /// `apps/macos/scripts/run_linux_tests.sh`). It is a pure function of two instants, so it touches no
    /// environment, no filesystem, and no systemd.
    @Suite struct TerminalServiceSystemdStartDeadlineTests {
        /// A caller with a tight budget owns the whole window: waiting on `systemctl` stops at the
        /// caller's deadline instead of running the full systemd start allowance past it.
        @Test func waitStopsAtACallerDeadlineTighterThanTheStartAllowance() {
            let now = Date()

            #expect(TerminalService.systemdStartWaitDeadline(overallDeadline: now.addingTimeInterval(0.5), now: now) == now.addingTimeInterval(0.5))
        }

        /// A generous caller budget is still capped, so an unresponsive systemd cannot consume the window
        /// and leave nothing for the socket wait that actually decides whether a daemon answered.
        @Test func waitIsCappedWhenTheCallerAllowsMoreThanTheStartAllowance() {
            let now = Date()

            #expect(TerminalService.systemdStartWaitDeadline(overallDeadline: now.addingTimeInterval(60), now: now) == now.addingTimeInterval(5))
        }

        /// An already-elapsed budget yields no wait at all rather than a fresh allowance.
        @Test func anExpiredCallerDeadlineLeavesNoWait() {
            let now = Date()
            let expired = now.addingTimeInterval(-1)

            #expect(TerminalService.systemdStartWaitDeadline(overallDeadline: expired, now: now) == expired)
        }
    }
#endif
