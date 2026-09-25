import Foundation

/// Serializes at-most-one in-flight operation per key: entering while the key is
/// already held fails immediately instead of waiting, unless the caller asks to wait.
final class PerKeyGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var inFlight: Set<String> = []

    /// Runs `operation` while holding `key`, or throws `busyError()` if the key is already held.
    func withKey<T>(_ key: String, busyError: () -> Error, operation: () throws -> T) throws -> T {
        condition.lock()
        if inFlight.contains(key) {
            condition.unlock()
            throw busyError()
        }
        inFlight.insert(key)
        condition.unlock()

        defer { release(key) }
        return try operation()
    }

    /// Runs `operation` while holding `key`, blocking the calling thread until the current holder leaves.
    ///
    /// For work that has no later chance to run: a caller that reconciles persisted state and is never
    /// retried cannot report a held key as a no-op, because the holder does not necessarily do the same
    /// reconcile on its way out. Every holder of a key is a bounded operation, so the wait ends; it is the
    /// caller's job to be on a thread that can afford to block.
    func withKeyWaiting<T>(_ key: String, operation: () throws -> T) throws -> T {
        condition.lock()
        while inFlight.contains(key) { condition.wait() }
        inFlight.insert(key)
        condition.unlock()

        defer { release(key) }
        return try operation()
    }

    private func release(_ key: String) {
        condition.lock()
        inFlight.remove(key)
        condition.broadcast()
        condition.unlock()
    }
}
