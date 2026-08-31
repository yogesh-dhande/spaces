import Dispatch
import Foundation

/// Bridges a single async `NWConnection` completion into a synchronous, throwing call.
///
/// Every pinned-TLS client in this codebase (the terminal-service TLS session client, the
/// pinned-TLS line connection, and the e2e Device API probe) needs request/response semantics on
/// top of `NWConnection`'s callback-based API: connect, send one frame, and receive one line each
/// block the calling thread on a semaphore that the async completion handler signals from
/// `NWConnection`'s own delivery queue, with a deadline so a wedged connection can't hang the
/// caller forever. That create-semaphore / wait-with-deadline scaffolding was duplicated
/// identically across all three call sites; this factors it out. The box types, error mapping,
/// and line-framing that differ per call site stay with each caller.
public enum NWConnectionSyncBridge {
    /// Creates a semaphore, invokes `body(signal)` to kick off the async operation — `body` is
    /// expected to arrange for some completion handler to call `signal.signal()` — then blocks
    /// until that happens or `timeout` elapses. On timeout, calls and throws `onTimeout()`;
    /// callers use it both to produce the timeout error and to run any cleanup (e.g. cancelling
    /// the connection) that must happen before the throw.
    public static func waitForSignal(timeout: TimeInterval, onTimeout: () -> any Error, body: (_ signal: DispatchSemaphore) -> Void) throws {
        let signal = DispatchSemaphore(value: 0)
        body(signal)
        guard signal.wait(timeout: .now() + timeout) == .success else { throw onTimeout() }
    }
}
