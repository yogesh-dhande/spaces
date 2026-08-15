import Dispatch
import Foundation

/// The stack size a dedicated thread gets from `runOnDedicatedLargeStackThread`, matching what a
/// process's main thread is given by default. Ghostty creates surfaces (and, in its own non-headless
/// app, parses config and creates the app) on the main thread, so its init path is written and tested
/// against that much stack. `Thread.stackSize` rounds up to a multiple of 4 KB; 8 MB already is one.
let ghosttyLargeStackCallByteCount = 8 * 1024 * 1024

/// Runs `body` to completion on a freshly created thread with an explicit `ghosttyLargeStackCallByteCount`
/// stack, blocking the caller until it finishes, and returns its result or rethrows its error.
///
/// This exists because the terminal engine actor's work can run on whatever thread called into it
/// (`TerminalEngineActor.runSynchronously` bridges with `queue.sync`, so a transport's libdispatch
/// workqueue thread, with the platform-default ~512 KB stack, ends up running Ghostty calls that are
/// reached many Swift frames deep). Some of those calls need more stack than that: headless session
/// creation and Ghostty config parsing/app creation walk deep into Zig-side init code and have been
/// observed to fault at the stack guard page (SIGBUS / KERN_PROTECTION_FAILURE) a few frames inside
/// Ghostty when run on a thread that thin. Running the call on a thread sized like the main thread
/// removes that overflow risk without changing which thread the engine actor's own work runs on.
///
/// A new thread is created for every call rather than reusing one long-lived thread: the calls this
/// wraps (session creation, app/config creation) are rare, at most a handful per terminal session or
/// per daemon lifetime, so the cost of spinning up a thread is negligible, and creating one fresh each
/// time means no caller can grow an assumption that repeated calls land on the same thread.
func runOnDedicatedLargeStackThread<T>(_ body: @escaping @Sendable () throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)

    // `outcome` is written exactly once, by the thread's closure below, strictly before that closure
    // signals `semaphore`; this function reads it only after `semaphore.wait()` returns. The
    // semaphore's wait/signal pair is a happens-before edge, so the write is visible before the read
    // even though `nonisolated(unsafe)` opts the compiler out of proving that itself.
    nonisolated(unsafe) var outcome: Result<T, Error>?

    let thread = Thread {
        outcome = Result { try body() }
        semaphore.signal()
    }
    thread.stackSize = ghosttyLargeStackCallByteCount
    thread.start()
    semaphore.wait()

    // `thread`'s closure always runs (Thread.start() cannot silently drop the closure) and always
    // signals before returning, so `outcome` is guaranteed set by the time `wait()` returns.
    return try outcome!.get()
}
