import Dispatch
import Foundation

/// What became of one control-request send's bytes at the session's PTY.
public enum TerminalInputWriteOutcome: Sendable, Equatable {
    /// Every byte of the send was handed to the session's PTY.
    case delivered
    /// The session had no live surface or PTY left to write to, so the bytes went nowhere. This is the
    /// outcome a send that raced the session's teardown gets, and it is a failure — never a silent no-op.
    case notDelivered
}

/// What a submit's text write did, as the write itself observed it: whether the bytes reached the PTY
/// and, when they did, whether the paste encoder framed them with bracketed-paste markers.
///
/// The framing is reported BY the write rather than sampled before it because the CR that submits the
/// text has to be paced against the framing the text actually went out with (see
/// `TerminalControlInputSequencer`), and on the embedded (macOS) path ghostty derives that framing from
/// live terminal state at write time. Reporting it from inside the write is what binds the two together.
public enum TerminalSubmitTextWriteOutcome: Sendable, Equatable {
    case written(framed: Bool)
    case notDelivered
}

/// The PTY writes one input call produced, awaited together.
///
/// An embedded (macOS) send does not write to the PTY itself: it hands text or bytes to ghostty, which
/// encodes them and calls back into the session's host PTY driver, possibly more than once. The writes
/// that callback enqueued are the only evidence of what actually reached the child, so the send collects
/// them and answers with their combined outcome instead of with "ghostty accepted the input".
///
/// An empty batch is `.notDelivered` on purpose: it means the call produced no PTY write at all, so
/// nothing reached the child, and reporting delivery for it would restore exactly the blind spot this
/// type exists to close.
public struct TerminalInputWriteBatch: Sendable {
    public let acknowledgements: [TerminalInputWriteAcknowledgement]

    public init(_ acknowledgements: [TerminalInputWriteAcknowledgement]) { self.acknowledgements = acknowledgements }

    /// Suspends until every write in the batch has run and reports `.delivered` only when all of them
    /// reached the PTY. Sequential because the writes themselves run in order on one serial queue.
    public func outcome() async -> TerminalInputWriteOutcome {
        guard !acknowledgements.isEmpty else { return .notDelivered }
        for acknowledgement in acknowledgements { if await acknowledgement.outcome() == .notDelivered { return .notDelivered } }
        return .delivered
    }
}

/// Resolves once a control-request send's enqueued writes have actually run against the session,
/// carrying whether the bytes reached the PTY.
///
/// A send is enqueued onto `TerminalControlInputSequencer` and written later, on the terminal engine
/// actor. Without this, "the request was accepted" is all a caller can ever learn, and a write that
/// found no surface (the session ended in between) is indistinguishable from one that landed — which is
/// exactly how an automation run could record a seed prompt as delivered that no agent ever received.
/// The send chokepoints hand this back to their off-engine callers, who wait on it and turn a
/// `notDelivered` into a failed response.
public final class TerminalInputWriteAcknowledgement: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var resolvedOutcome: TerminalInputWriteOutcome?
    private var suspendedWaiters: [@Sendable (TerminalInputWriteOutcome) -> Void] = []

    public init() {}

    /// Records the outcome and wakes every waiter. Only the first call counts: a submit that fails its
    /// text write resolves there and never reaches its carriage return.
    public func resolve(_ outcome: TerminalInputWriteOutcome) {
        lock.lock()
        guard resolvedOutcome == nil else {
            lock.unlock()
            return
        }
        resolvedOutcome = outcome
        let waiters = suspendedWaiters
        suspendedWaiters = []
        lock.unlock()
        semaphore.signal()
        for waiter in waiters { waiter(outcome) }
    }

    /// Suspends until the write has run and returns what it did. This is the waiter for callers already
    /// in async context — the sequencer's own write closures, which chain a driver-level write into the
    /// outcome they report — so waiting costs a suspension rather than a blocked thread.
    public func outcome() async -> TerminalInputWriteOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<TerminalInputWriteOutcome, Never>) in
            lock.lock()
            if let resolvedOutcome {
                lock.unlock()
                continuation.resume(returning: resolvedOutcome)
                return
            }
            suspendedWaiters.append { continuation.resume(returning: $0) }
            lock.unlock()
        }
    }

    /// Blocks the calling thread until the writes have run, returning nil when `timeout` elapses first.
    /// This is the waiter for the synchronous control-request callers; `outcome()` is the async one.
    ///
    /// MUST NOT be called from the terminal engine actor (the writes it waits for run there, so waiting
    /// on the engine deadlocks until the timeout) nor from the main actor. The callers are transport
    /// threads: a session's control-socket queue, and the daemon's off-main send path.
    public func wait(timeout: DispatchTimeInterval) -> TerminalInputWriteOutcome? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return resolvedOutcome
    }
}
