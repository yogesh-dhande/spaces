import Foundation

/// Serializes at-most-one in-flight operation per key: entering while the key is
/// already held fails immediately instead of waiting.
final class PerKeyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: Set<String> = []

    /// Runs `operation` while holding `key`, or throws `busyError()` if the key is already held.
    func withKey<T>(_ key: String, busyError: () -> Error, operation: () throws -> T) throws -> T {
        lock.lock()
        if inFlight.contains(key) {
            lock.unlock()
            throw busyError()
        }
        inFlight.insert(key)
        lock.unlock()

        defer {
            lock.lock()
            inFlight.remove(key)
            lock.unlock()
        }
        return try operation()
    }
}
