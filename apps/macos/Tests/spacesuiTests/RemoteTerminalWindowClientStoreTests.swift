import Foundation
import Testing
import spacesterminalcore

@testable import spacesui

/// Exercises `TerminalPaneService.RemoteTerminalWindowClientStore`'s heartbeat stop rule: once
/// `heartbeatAction` answers that the daemon no longer holds this pane's client (the case once a
/// session ends and the pane keeps showing its final render), the timer must stop rather than firing a
/// doomed heartbeat forever, and a re-attach that races that in-flight answer must not be stranded
/// without a keep-alive.
@Suite struct RemoteTerminalWindowClientStoreTests {
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }

        func current() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Timer ticks are scheduled on a global queue that a loaded machine can starve for far longer than
    /// the test's short interval, so every count is awaited up to a generous deadline rather than read
    /// after a fixed sleep; the timing the tests care about is ordering, not latency.
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: Duration = .seconds(10)) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The stop rule reads the daemon's own verdict, wherever it reports it: the session core answers on
    /// the nested control response, and the daemon's request router (a session whose core is gone)
    /// answers on the outer response. Any other refusal, and every success, keeps the heartbeat going.
    @Test func heartbeatStopRuleReadsTheDaemonsVerdictFromEitherResponseLevel() {
        #expect(TerminalPaneService.heartbeatShouldContinue(after: TerminalServiceResponse(ok: true, message: "ok")))
        #expect(
            !TerminalPaneService.heartbeatShouldContinue(
                after: TerminalServiceResponse(
                    ok: false, message: "gone",
                    controlResponse: TerminalControlResponse(ok: false, message: "Terminal client is no longer attached.", errorCode: .notFound))))
        #expect(
            !TerminalPaneService.heartbeatShouldContinue(
                after: TerminalServiceResponse(ok: false, message: "Terminal session is not running.", errorCode: .sessionNotRunning)))
        #expect(
            TerminalPaneService.heartbeatShouldContinue(
                after: TerminalServiceResponse(
                    ok: false, message: "busy", controlResponse: TerminalControlResponse(ok: false, message: "busy", errorCode: .busy))))
    }

    @Test func heartbeatStopsOnceTheDaemonAnswersThatTheClientIsGone() async throws {
        let counter = CallCounter()
        let store = TerminalPaneService.RemoteTerminalWindowClientStore(
            heartbeatAction: { _ in
                _ = counter.increment()
                return false
            }, heartbeatInterval: 0.05)

        store.set("client")
        #expect(try await waitUntil { counter.current() == 1 })
        // Several intervals in which a timer that ignored the answer would have fired again.
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.current() == 1)

        // A later attach re-arms the timer, same as any real reattachment.
        store.set("client")
        #expect(try await waitUntil { counter.current() > 1 })
    }

    @Test func heartbeatKeepsGoingWhenTheAnswerArrivesAfterAReattach() async throws {
        let counter = CallCounter()
        final class StoreBox: @unchecked Sendable { weak var store: TerminalPaneService.RemoteTerminalWindowClientStore? }
        let box = StoreBox()

        let store = TerminalPaneService.RemoteTerminalWindowClientStore(
            heartbeatAction: { clientID in
                // The first heartbeat was sent for an attachment the daemon had already dropped, and the
                // pane re-attaches (calling `set`) while that answer is still in flight, so the stale
                // `false` must not cancel the timer. Every later heartbeat is for the fresh attachment,
                // which the daemon holds, so it answers ok.
                let call = counter.increment()
                guard call == 1 else { return true }
                box.store?.set(clientID)
                return false
            }, heartbeatInterval: 0.05)
        box.store = store

        store.set("client")
        #expect(try await waitUntil { counter.current() >= 3 })
    }
}
