import Dispatch
import Foundation

/// Dedicated serial executor for the embedded-terminal engine, kept OFF the main actor so a blocked
/// main actor can never freeze terminal I/O. The daemon's main actor owns coordination only; the
/// terminal engine (GhosttyKit sessions, PTY read loops, render broadcast) runs here on its own queue.
///
/// ## The one-way rule (what makes this design deadlock-free)
/// - Code running on the terminal engine actor MAY synchronously hop to the main actor for the rare
///   AppKit needs (NSView construction, `NSScreen`/`NSApp` reads) via `DispatchQueue.main.sync`.
/// - Code running on the main actor MUST NEVER synchronously wait on the terminal engine actor. It hops
///   with the async `run(_:)` helper (or a `Task { @TerminalEngineActor in }`). A synchronous wait in
///   that direction, combined with the legal engine→main hop above, would deadlock the two queues.
///
/// The actor is backed by its own serial `DispatchQueue`. On Darwin the queue is a
/// `DispatchSerialQueue`, whose overlay conformance to `SerialExecutor` makes it the actor's executor
/// directly. swift-corelibs-dispatch on Linux does NOT vend `DispatchSerialQueue`, so there the queue
/// is a plain (serial) `DispatchQueue` wrapped in `TerminalEngineSerialExecutor`, a hand-rolled
/// `SerialExecutor` that enqueues actor jobs onto that same queue. Either way ONE queue backs both the
/// actor's executor and the synchronous `runSynchronously` bridge, so a transport thread can enter the
/// actor's isolation domain synchronously (`queue.sync`) — the daemon's socket workers answer live-core
/// control/state requests without an async hop, exactly as they previously did against the main actor.
@globalActor
public actor TerminalEngineActor {
    public static let shared = TerminalEngineActor()

    /// Marks the actor's own serial queue so `runSynchronously` can detect a same-queue reentrant call
    /// (a `queue.sync` from within the queue would deadlock) and run inline instead — mirroring the old
    /// main-actor bridges' `Thread.isMainThread` fast path.
    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queueMarker: UInt8 = 0x5A

    #if os(Linux)
        /// The serial queue backing BOTH the actor's executor and the synchronous bridge.
        public nonisolated let queue: DispatchQueue
        private nonisolated let serialExecutor: TerminalEngineSerialExecutor

        private init() {
            let queue = DispatchQueue(label: "spaces.terminal.engine")
            queue.setSpecific(key: TerminalEngineActor.queueKey, value: TerminalEngineActor.queueMarker)
            self.queue = queue
            serialExecutor = TerminalEngineSerialExecutor(queue: queue)
        }

        public nonisolated var unownedExecutor: UnownedSerialExecutor { serialExecutor.asUnownedSerialExecutor() }
    #else
        /// The serial queue backing BOTH the actor's executor and the synchronous bridge.
        public nonisolated let queue: DispatchSerialQueue

        private init() {
            let queue = DispatchSerialQueue(label: "spaces.terminal.engine")
            queue.setSpecific(key: TerminalEngineActor.queueKey, value: TerminalEngineActor.queueMarker)
            self.queue = queue
        }

        public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    #endif

    /// True when the calling thread is already running on the engine queue.
    private nonisolated static var isOnEngineQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == queueMarker }

    /// Enters the engine's isolation domain from a NON-main, non-engine thread and runs `body`
    /// synchronously, returning its result. When already on the engine queue, runs inline (the
    /// reentrancy guard). NEVER call this from the main actor — see the one-way rule; use `run(_:)`.
    ///
    /// Throwing bodies wrap their work in `Result { ... }.get()` at the call site (as the daemon's
    /// existing bridges do), so this stays non-throwing and matches the old `runOnMainActorSynchronously`
    /// shape.
    public nonisolated static func runSynchronously<T: Sendable>(_ body: @TerminalEngineActor () -> T) -> T {
        if isOnEngineQueue { return assumeIsolated(body) }
        // Enforce the one-way rule, not just document it: a main-thread caller synchronously waiting on
        // the engine can deadlock against the engine's legal synchronous hops TO main (session-creation
        // AppKit work), so it must fail loudly here rather than hang intermittently in the field.
        precondition(!Thread.isMainThread, "runSynchronously must never be called from the main actor/thread; use run(_:) — see the one-way rule")
        return shared.queue.sync { assumeIsolated(body) }
    }

    /// Async hop onto the engine actor for main-actor (or other) callers. Custom global actors have no
    /// `MainActor.run` equivalent, so this provides one; the suspension is the legal main→engine
    /// direction of the one-way rule.
    public static func run<T: Sendable>(_ body: @TerminalEngineActor () throws -> T) async rethrows -> T {
        try await body()
    }

    /// Runs `body` treating the current thread as already isolated to the engine actor. The caller MUST
    /// guarantee that dynamic isolation (it is called only from `runSynchronously`, which is either on
    /// the engine queue or inside `queue.sync`). This is the custom-global-actor analogue of
    /// `MainActor.assumeIsolated`, which the standard library provides only for `MainActor`. The
    /// `unsafeBitCast` reinterprets the actor-isolated closure as a non-isolated one; it is sound
    /// precisely because the caller has established the dynamic isolation.
    public nonisolated static func assumeIsolated<T>(_ body: @TerminalEngineActor () -> T) -> T {
        typealias NonIsolated = () -> T
        // `withoutActuallyEscaping` hands `escapingBody` back as escaping (the whole point), so
        // `unsafeBitCast` accepts it; the isolation is dropped only after the caller has guaranteed we
        // are dynamically on the engine queue.
        return withoutActuallyEscaping(body) { escapingBody in
            unsafeBitCast(escapingBody, to: NonIsolated.self)()
        }
    }
}

#if os(Linux)
    /// Backs `TerminalEngineActor` on Linux, where swift-corelibs-dispatch does not expose the
    /// Darwin overlay's `DispatchSerialQueue` (which conforms to `SerialExecutor` on its own). Actor
    /// jobs are dispatched onto the same serial `DispatchQueue` the actor's `runSynchronously` bridge
    /// enters with `queue.sync`, so both share one isolation domain exactly as the Darwin path does.
    private final class TerminalEngineSerialExecutor: SerialExecutor {
        private let queue: DispatchQueue

        init(queue: DispatchQueue) { self.queue = queue }

        func enqueue(_ job: consuming ExecutorJob) {
            let unownedJob = UnownedJob(job)
            let executor = asUnownedSerialExecutor()
            queue.async { unownedJob.runSynchronously(on: executor) }
        }

        func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }

        /// The runtime calls this to verify isolation when it cannot statically prove the current context
        /// is on this executor (e.g. `assumeIsolated`, and the isolation assertions the concurrency runtime
        /// inserts). Without an override, the protocol default traps unconditionally ("Unexpected isolation
        /// context") the first time any engine-isolated job runs. `dispatchPrecondition(.onQueue:)` passes
        /// both when the queue runs a job (`queue.async`) and when a thread enters it via `queue.sync` (the
        /// `runSynchronously` bridge), matching what Darwin's `DispatchSerialQueue` provides for free.
        func checkIsolated() { dispatchPrecondition(condition: .onQueue(queue)) }
    }
#endif
