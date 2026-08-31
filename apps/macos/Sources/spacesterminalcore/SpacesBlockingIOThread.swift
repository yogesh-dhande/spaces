import Foundation

/// Runs blocking transport I/O on its own detached thread, never on the Swift cooperative pool.
///
/// The pool has one thread per core and no reserve: a pool thread parked in a blocking wait can leave
/// every async task in the process unschedulable, and on a 3-core CI runner three such parked waits
/// deadlocked the whole test process (issue #611). GCD's non-overcommit queues are not a safe home
/// either — with the kernel workqueue saturated by those same parked pool threads they are never
/// provisioned a thread of their own — so this spawns a real `Thread` per call, which the OS is
/// guaranteed to start regardless of how many other threads are already blocked.
public enum SpacesBlockingIOThread {
    /// Fire-and-forget: runs `body` on a new detached thread. Callers that need the result use `run`.
    ///
    /// A raw `Thread` gets none of the autorelease pool that `Foundation`/`Network` machinery (URL
    /// loading, pinned-TLS connections) expects its calling thread to provide, so every call would
    /// otherwise leak the autoreleased objects that body's blocking I/O produces. `autoreleasepool`
    /// itself is an Objective-C runtime facility corelibs-foundation on Linux doesn't implement, so
    /// it's wrapped only where `ObjectiveC` exists; the pool is unnecessary there since Linux has no
    /// autorelease machinery to drain.
    ///
    /// `name` is a best-effort diagnostic: Linux's pthread API caps thread names at 15 bytes, so a
    /// longer name silently fails to apply there and reads back truncated.
    public static func spawn(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread {
            #if canImport(ObjectiveC)
                autoreleasepool { body() }
            #else
                body()
            #endif
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Runs `body` on a new detached thread and resumes the awaiting task with its result.
    ///
    /// The await is deliberately not cancellable: the blocking body cannot be interrupted mid-syscall,
    /// matching the prior `Task.detached { ... }.value` behavior this replaces.
    public static func run<T: Sendable>(name: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>, Never>) in
            spawn(name: name) { continuation.resume(returning: Result { try body() }) }
        }
        return try result.get()
    }
}
