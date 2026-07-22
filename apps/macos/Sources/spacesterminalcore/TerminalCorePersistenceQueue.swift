import Dispatch
import Foundation

/// Latest-wins coalescing gate for keyed durable writes on a `TerminalCorePersistenceQueue`. The engine
/// bumps a key's generation as it enqueues each write; a queued write runs only if its generation is still
/// the latest for that key, so a burst of writes for the same key (lease touches for a client, successive
/// runtime-state persists) collapses to a single write of the newest value. Shared between the engine
/// (which bumps) and the persistence queue (which checks), hence lock-guarded and `@unchecked Sendable`.
private final class PersistenceCoalescingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestGeneration: [String: UInt64] = [:]

    func nextGeneration(forKey key: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (latestGeneration[key] ?? 0) &+ 1
        latestGeneration[key] = next
        return next
    }

    func isLatest(_ generation: UInt64, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestGeneration[key] == generation
    }
}

/// Per-core serial background executor for a terminal session core's durable SQLite writes, shared by the
/// macOS embedded core and the Linux headless core. Every mutation the engine used to perform synchronously
/// on its critical path — per-request client lease touches, the runtime-state timer's persist, stale-client
/// expiry detaches, the final terminated payload — is enqueued here instead. SQLite runs in WAL mode with a
/// 5s busy timeout: a competing writer (e.g. an agent hook's `spaces agent signal` burst) makes any WRITE
/// block on the write lock up to that timeout, which on the engine executor froze all terminal I/O; WAL
/// READS never block on a writer, so reads stay inline on the engine. Writes commit in enqueue order (serial
/// queue); the DB is a durable mirror that converges while the engine's in-memory state stays authoritative
/// for reads and broadcasts. Handoff drains this queue before `execv` so the staged daemon reads a complete
/// mirror; termination enqueues its final writes last so FIFO ordering lands the terminated payload after
/// every pending mirror write.
public final class TerminalCorePersistenceQueue: Sendable {
    /// Coalescing key for the runtime-state write chain; a fresh persist supersedes any still-queued one.
    /// Namespaced so it never collides with per-client lease-touch keys (`lease:<clientID>`).
    public static let runtimeStateCoalescingKey = "runtime_state"
    /// Bounded retry policy for a failed runtime-state write, applied to every state (not just `.exited`). The
    /// Linux headless core has no periodic runtime-state refresh — its persists are purely event-driven
    /// (startup, per output chunk, attach/detach/takeover/resize/handoff, terminate) — so a dropped write of
    /// any state leaves stale durable metadata until the next event. A superseded write abandons its retry
    /// (latest-wins), so a running-state retry can never overwrite a newer state.
    public static let runtimeStateWriteMaxAttempts = 5
    public static let runtimeStateWriteRetryDelay: TimeInterval = 0.2

    private let queue: DispatchQueue
    private let coalescingGate = PersistenceCoalescingGate()

    public init(label: String) {
        queue = DispatchQueue(label: label)
    }

    /// Enqueue a durable write with no coalescing (unique mutations: expiry detaches, ownership transfer,
    /// the terminated payload). Runs on the serial persistence queue in enqueue (FIFO) order.
    public func enqueueWrite(_ write: @escaping @Sendable () -> Void) {
        queue.async(execute: write)
    }

    /// Enqueue a latest-wins coalesced durable write for `key`: only the newest enqueue runs; a burst
    /// collapses to one write of the newest value (see `PersistenceCoalescingGate`). FIFO order across keys.
    public func enqueueCoalescedWrite(key: String, _ write: @escaping @Sendable () -> Void) {
        let generation = coalescingGate.nextGeneration(forKey: key)
        let gate = coalescingGate
        queue.async {
            guard gate.isLatest(generation, forKey: key) else { return }
            write()
        }
    }

    /// Blocks the caller until every write enqueued so far has committed. Deadlock-free from the engine:
    /// persistence closures only ever hop BACK to the engine asynchronously (`Task { @TerminalEngineActor }`),
    /// never with a synchronous wait, so a blocked engine cannot cycle with the queue. Used only for the
    /// handoff/termination fences and test determinism — never on the per-keystroke path.
    public func drain() {
        queue.sync {}
    }

    /// Async drain for the handoff quiesce and daemon-shutdown paths: suspends (rather than blocking the
    /// engine) until the persistence queue is empty, so every mirror write is durable before the caller
    /// `execv`s or `exit`s.
    public func drainAsync() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    /// Runs one durable runtime-state write on the serial queue. On failure it retries IN PLACE inside the
    /// single queued work item — looping up to `runtimeStateWriteMaxAttempts` with a `Thread.sleep` back-off
    /// between attempts — rather than re-enqueuing. Every state retries, not just `.exited`: the Linux headless
    /// core has no periodic refresh, so a dropped write of any state (running included) would otherwise leave
    /// stale durable metadata until the next event. Blocking the per-core persistence queue here IS the
    /// termination fence: it holds this write's FIFO position so the detach-all, terminated payload, and
    /// trailing durable-end notification enqueued after it in a core's `terminate()` cannot run — and `execv`
    /// cannot destroy the pending retry by jumping ahead of it — until the exited state commits. It only ever
    /// blocks this core's serial persistence queue, never the engine executor, so it cannot stall live
    /// sessions. Closed only over value types plus the shared gate, so the retry never depends on the core
    /// staying alive. The coalescing generation is taken up front and re-checked each attempt, so a newer state
    /// enqueued behind this one still supersedes it (latest-wins) and a superseded write abandons its retry.
    /// `onPersisted` hops back to the engine to advance the durable marker (one-way rule); it is the ONLY
    /// reference to the core in the write chain, so the write — and any retry — survives the core's release
    /// (e.g. a session-close that drops the core right after termination).
    public func enqueueRuntimeStateWrite(
        _ state: TerminalSessionRuntimeState, at writeAt: Date, paths: TerminalSessionPaths,
        onPersisted: @escaping @Sendable (TerminalSessionRuntimeState, Date) -> Void
    ) {
        let key = Self.runtimeStateCoalescingKey
        let maxAttempts = Self.runtimeStateWriteMaxAttempts
        let retryDelay = Self.runtimeStateWriteRetryDelay
        let gate = coalescingGate
        let generation = gate.nextGeneration(forKey: key)
        queue.async {
            var attempt = 0
            while true {
                guard gate.isLatest(generation, forKey: key) else { return }
                do {
                    try TerminalSessionPersistence.writeRuntimeState(state, paths: paths)
                } catch {
                    attempt += 1
                    guard attempt < maxAttempts else { return }
                    Thread.sleep(forTimeInterval: retryDelay)
                    continue
                }
                onPersisted(state, writeAt)
                return
            }
        }
    }
}
