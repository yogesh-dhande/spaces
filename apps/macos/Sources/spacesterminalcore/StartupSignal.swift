import Dispatch
import Foundation

/// A one-shot, thread-safe handoff from an asynchronous listener-startup callback
/// (e.g. an `NWListener.stateUpdateHandler` firing on its own queue) back to a
/// synchronous `start(timeout:)` call. The first `signal(_:)` call wins; later
/// calls are ignored so a late `.failed` callback can't clobber an already-observed
/// `.ready`, or vice versa.
public final class StartupSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    public init() {}

    public func signal(_ result: Result<Void, Error>) {
        lock.lock()
        let shouldSignal = self.result == nil
        if shouldSignal { self.result = result }
        lock.unlock()
        if shouldSignal { semaphore.signal() }
    }

    /// Waits up to `timeout` for a signal. Returns `nil` if none arrived in time so
    /// each call site can throw its own timeout error; a stored result (success or
    /// failure) is otherwise returned as-is.
    public func wait(timeout: TimeInterval) -> Result<Void, Error>? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
