import Foundation

/// Lock-guarded error/data hand-off between a connection's callback queue and a
/// semaphore-blocked caller.
public final class TransportResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?
    private var storedResponseData = Data()

    public init() {}

    /// Records an error, overwriting any previously recorded one (last write wins).
    public func setError(_ error: any Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    /// Records an error only if none has been recorded yet (first write wins).
    public func setErrorIfUnset(_ error: any Error) {
        lock.lock()
        if storedError == nil { storedError = error }
        lock.unlock()
    }

    public func error() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    public func setResponseData(_ data: Data) {
        lock.lock()
        storedResponseData = data
        lock.unlock()
    }

    public func responseData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storedResponseData
    }
}
