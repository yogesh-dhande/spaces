import Foundation
import Testing

@testable import spacesui

private struct StubPingFailure: Error, Equatable { let reason: String }

/// A scripted local daemon: answers or refuses the liveness ping on demand, and counts the attempts so
/// a test can prove the probe pings once per run and not at all when it is skipped.
private final class StubDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?
    private var attempts = 0
    /// Blocks every attempt until released, so a test can hold one probe open and drive a second.
    private let gate = DispatchSemaphore(value: 0)
    private var isGated = false

    init(failure: (any Error)? = nil) { self.failure = failure }

    func setFailure(_ value: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        failure = value
    }

    func gateAttempts() {
        lock.lock()
        isGated = true
        lock.unlock()
    }

    func releaseGatedAttempt() { gate.signal() }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    var attempt: LocalDaemonReachabilityProbe.LivenessAttempt {
        { [self] in
            lock.lock()
            attempts += 1
            let gated = isGated
            let outcome = failure
            lock.unlock()
            if gated { gate.wait() }
            return outcome
        }
    }
}

/// Behavior of the detection half of local-daemon offline handling: what the sidebar's reachability
/// watchdog learns from one liveness probe of this Mac's daemon, and — critically — how often it is
/// told to act on it. The rendering and recovery halves are driven by the sidebar snapshot and are
/// covered elsewhere; this suite pins the signal that makes them run at all.
@Suite @MainActor struct LocalDaemonReachabilityProbeTests {
    /// The bug this exists for: a daemon that dies while the app is idle commits nothing, so no
    /// database-change snapshot runs and the local section keeps claiming to be loaded. The probe is
    /// the only evidence that it is gone.
    @Test func aDaemonThatStopsAnsweringIsReportedAsLostContact() async {
        let daemon = StubDaemon()
        let probe = LocalDaemonReachabilityProbe(attempt: daemon.attempt)

        guard case .noChange = await probe.run() else {
            Issue.record("a daemon that answers must not be reported as a change while it keeps answering")
            return
        }

        daemon.setFailure(StubPingFailure(reason: "connection refused"))
        guard case .lostContact(let error) = await probe.run() else {
            Issue.record("a daemon that stopped answering must be reported so the sidebar re-derives its section")
            return
        }
        #expect(error as? StubPingFailure == StubPingFailure(reason: "connection refused"))
    }

    /// The cost constraint. Acting on the standing verdict rather than the change would rebuild the
    /// whole sidebar every 15s for as long as the daemon stays down; the reload the first report
    /// triggers is what installs the offline section, and the watchdog's not-loaded branch owns the
    /// retries from there.
    @Test func anOutageIsReportedOnceRatherThanOnEveryProbe() async {
        let daemon = StubDaemon(failure: StubPingFailure(reason: "connection refused"))
        let probe = LocalDaemonReachabilityProbe(attempt: daemon.attempt)

        guard case .lostContact = await probe.run() else {
            Issue.record("the first probe of a dead daemon must report the outage")
            return
        }
        for _ in 0..<3 {
            guard case .noChange = await probe.run() else {
                Issue.record("a daemon that stays down must not be re-reported; the reload it already triggered owns the recovery")
                return
            }
        }
    }

    /// Detection must re-arm, so a second outage in the same app session is reported like the first.
    @Test func aDaemonThatAnswersAgainReportsRecoveryAndRearmsDetection() async {
        let daemon = StubDaemon(failure: StubPingFailure(reason: "connection refused"))
        let probe = LocalDaemonReachabilityProbe(attempt: daemon.attempt)
        _ = await probe.run()

        daemon.setFailure(nil)
        guard case .regainedContact = await probe.run() else {
            Issue.record("a daemon that answers again must be reported once so the trace shows the outage ending")
            return
        }
        guard case .noChange = await probe.run() else {
            Issue.record("a healthy daemon must stay silent")
            return
        }

        daemon.setFailure(StubPingFailure(reason: "socket vanished"))
        guard case .lostContact = await probe.run() else {
            Issue.record("a second outage must be detected, not swallowed by the first one's verdict")
            return
        }
    }

    /// A wedged daemon accepts the connection and then answers nothing until the socket read times out,
    /// which can outlast a watchdog tick. Probes must not stack up on it.
    @Test func aProbeThatHasNotAnsweredYetIsNotRestartedByTheNextTick() async {
        let daemon = StubDaemon()
        daemon.gateAttempts()
        let probe = LocalDaemonReachabilityProbe(attempt: daemon.attempt)

        let outstanding = Task { await probe.run() }
        // The gated attempt is running once the stub has been entered; until then the first probe may
        // not have reached it yet, and the second probe's skip would prove nothing.
        var spins = 0
        while daemon.attemptCount == 0, spins < 10_000 {
            spins += 1
            await Task.yield()
        }
        guard daemon.attemptCount == 1 else {
            Issue.record("the first probe never reached the daemon")
            daemon.releaseGatedAttempt()
            return
        }

        guard case .noChange = await probe.run() else {
            Issue.record("a tick landing while an attempt is outstanding must skip rather than open a second one")
            return
        }
        #expect(daemon.attemptCount == 1)

        daemon.releaseGatedAttempt()
        _ = await outstanding.value
    }
}
