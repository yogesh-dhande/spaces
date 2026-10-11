#if os(Linux)
    import Foundation
    import Glibc
    import Testing
    import spacesterminalcore

    @testable import spacesterminalghostty

    /// Covers the termination ladder of `HostManagedPTYTerminalSessionDriver` after the session leader has
    /// already been reaped (#214). Linux-only: on macOS the kernel revokes the terminal for every holder of
    /// the slave when the leader exits, so the master reads EOF within milliseconds and escalation never
    /// runs; on Linux the slave stays valid, the read loop stays blocked, and escalation must proceed.
    ///
    /// Swift Testing, because corelibs-xctest deadlocks async tests on Linux. `.serialized` because the
    /// test owns a real PTY child and a signalling driver.
    @Suite(.serialized) struct HostManagedPTYEscalationLinuxTests {
        /// Thread-safe log of the signals the driver sent and of the closed handler firing.
        private final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var signals: [(target: Int32, signal: Int32)] = []
            private var closed = false

            func record(target: Int32, signal: Int32) {
                lock.lock()
                signals.append((target, signal))
                lock.unlock()
            }

            func markClosed() {
                lock.lock()
                closed = true
                lock.unlock()
            }

            var snapshot: [(target: Int32, signal: Int32)] {
                lock.lock()
                defer { lock.unlock() }
                return signals
            }

            var isClosed: Bool {
                lock.lock()
                defer { lock.unlock() }
                return closed
            }
        }

        private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                usleep(5_000)
            }
            return condition()
        }

        /// Once escalation has reaped the leader its pid may be reused by an unrelated process, so later
        /// stages must signal only the process group. The descendant ignores SIGHUP and holds the slave, so
        /// the session only closes when the group is escalated to SIGTERM. The leader ignores SIGHUP before
        /// forking so the descendant inherits it: a trap set inside the subshell races the leader's exit,
        /// whose SIGHUP kills the subshell first.
        @Test func escalationAfterReapingTheLeaderSignalsOnlyTheProcessGroup() throws {
            let recorder = Recorder()
            let intervals = HostManagedPTYTerminalSessionDriver.TerminationEscalationIntervals(hupGrace: 0.2, termGrace: 0.5, killGrace: 0.5)
            let configuration = TerminalSessionLaunchConfiguration(
                sessionID: "escalation-reaped-leader-\(UUID().uuidString)", title: "escalation-test",
                workingDirectory: FileManager.default.temporaryDirectory.path, shell: "/bin/sh", command: "trap '' HUP; (exec sleep 30) & exit 0",
                createdAt: "2026-10-10T00:00:00Z", workspaceID: "workspace-escalation", kind: .shell)
            let driver = HostManagedPTYTerminalSessionDriver(
                launchConfiguration: configuration, terminationEscalationIntervals: intervals,
                signalAction: { target, signal in
                    recorder.record(target: target, signal: signal)
                    _ = kill(target, signal)
                })
            driver.setSessionClosedHandler { recorder.markClosed() }
            try driver.startIfNeeded()
            #expect(waitUntil(timeout: 10) { driver.childPID() != nil }, "child never came up")
            let childPID = try #require(driver.childPID())

            // Let the leader spawn the descendant and exit on its own; the descendant keeps the read loop blocked.
            usleep(200_000)
            driver.terminate()

            #expect(waitUntil(timeout: 10) { recorder.isClosed }, "session never closed, so escalation did not run")
            let recorded = recorder.snapshot
            #expect(recorded.contains { $0.target == -childPID && $0.signal == SIGTERM }, "the group was not escalated to SIGTERM: \(recorded)")
            #expect(
                !recorded.contains { $0.target == childPID && ($0.signal == SIGTERM || $0.signal == SIGKILL) },
                "the reaped leader's pid was signalled during escalation: \(recorded)")
        }
    }
#endif
