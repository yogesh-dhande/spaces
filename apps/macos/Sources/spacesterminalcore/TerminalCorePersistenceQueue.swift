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

/// Per-client heartbeat generation counter shared between the terminal engine and its per-core persistence
/// queue, so a stale-client expiry that is queued behind a client's still-uncommitted heartbeat can still veto
/// detaching that client. The engine bumps a client's generation the moment a heartbeat (or any lease touch) is
/// accepted in memory — before its coalesced durable lease write is even enqueued. The expiry decision captures
/// each candidate's generation as it runs on the engine; the queued expiry transaction, once it has acquired
/// the DB write lock, re-reads the generation and skips (never detaches) any candidate whose generation
/// advanced. That last read happens INSIDE the write transaction on purpose: a heartbeat can land at any point
/// while the expiry blocks on a contended write lock (its own durable touch is stuck FIFO-behind the expiry, so
/// the committed lease row still looks stale), and only a check taken after the lock is held sees every such
/// heartbeat. Engine-isolated state cannot be read from the queue thread, so the map is carried across the
/// boundary by this lock-guarded `@unchecked Sendable` holder.
public final class TerminalClientHeartbeatGenerationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]

    public init() {}

    /// Engine-side: advances the client's heartbeat generation. Called synchronously the instant a heartbeat or
    /// lease touch is accepted in memory, before its coalesced durable write is enqueued.
    public func recordHeartbeat(forClientID clientID: String) {
        lock.lock()
        defer { lock.unlock() }
        generations[clientID] = (generations[clientID] ?? 0) &+ 1
    }

    /// Engine-side: snapshot the current generations for the expiry decision's candidates, to compare inside the
    /// queued expiry transaction.
    public func snapshot(forClientIDs clientIDs: [String]) -> [String: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: UInt64] = [:]
        for id in clientIDs { result[id] = generations[id] ?? 0 }
        return result
    }

    /// Queue-side: true when the client's generation advanced past the decision-time `observed` snapshot (a
    /// heartbeat landed after the expiry was decided), so the expiry must NOT detach it.
    public func generationAdvanced(forClientID clientID: String, since observed: [String: UInt64]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (generations[clientID] ?? 0) != (observed[clientID] ?? 0)
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
    /// Bounded retry policy shared by the two write kinds that must not be dropped: runtime state (applied to
    /// every state, not just `.exited`) and the once-per-lifecycle mirror writes (launch configuration, client
    /// upsert/attach/detach, ownership transfer). The Linux headless core has no periodic runtime-state
    /// refresh — its persists are purely event-driven (startup, per output chunk,
    /// attach/detach/takeover/resize/handoff, terminate) — so a dropped write of any state leaves stale durable
    /// metadata until the next event; a dropped lifecycle write leaves the durable mirror disagreeing with the
    /// authoritative in-memory snapshot that out-of-core readers (the orchestrator's session listing) still read
    /// through. A superseded runtime-state write abandons its retry (latest-wins), so a running-state retry can
    /// never overwrite a newer state.
    public static let writeMaxAttempts = 5
    /// Production back-off between retry attempts. Injectable via `init` (see `writeRetryDelay` below) so tests
    /// can virtualize the wait instead of stepping over it with a real sleep; this default is what every
    /// production call site gets.
    public static let writeRetryDelay: TimeInterval = 0.2

    private let queue: DispatchQueue
    private let coalescingGate = PersistenceCoalescingGate()
    private let writeRetryDelay: TimeInterval
    /// Back-off primitive for the retry loops, defaulting to a real `Thread.sleep`. Tests inject a
    /// non-blocking closure (e.g. one that just signals a semaphore) to observe/synchronize on a retry
    /// attempt without spending wall-clock time on it.
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        label: String, writeRetryDelay: TimeInterval = TerminalCorePersistenceQueue.writeRetryDelay,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        queue = DispatchQueue(label: label)
        self.writeRetryDelay = writeRetryDelay
        self.sleep = sleep
    }

    /// The database a queued write belongs to, resolved when the write is ENQUEUED and handed to it so it
    /// commits to the profile that was current when the engine decided the write — not to whatever profile
    /// is current whenever the serial queue reaches it. A daemon's profile never changes mid-process, so
    /// this is inert in production; it is what keeps a test's final writes (a core's `terminate()` returns
    /// with them still queued) inside the profile that test bound.
    private enum EnqueueTimeDatabase: Sendable {
        case resolved(String)
        /// Carries the failure's description rather than the error itself: this crosses onto the
        /// persistence queue, where `any Error` is not `Sendable`, and it only ever explains the write
        /// that was abandoned.
        case unresolved(reason: String)
    }

    /// Resolves the enqueue-time database, keeping "could not resolve" distinct from "resolved".
    ///
    /// A failure must NOT collapse into the persistence API's `nil`, which means "no explicit database,
    /// resolve the active profile when you run": that would let a write whose profile could not be
    /// determined commit to whatever profile happened to be current when the queue reached it — exactly
    /// the reassignment the enqueue-time capture exists to prevent. The failure is reachable, not
    /// theoretical: profile resolution refuses a live user profile in a test process, so a test bound
    /// inside one throws here.
    private static func enqueueTimeDatabase() -> EnqueueTimeDatabase {
        do { return .resolved(try TerminalSessionPersistence.currentDatabasePath()) } catch { return .unresolved(reason: String(describing: error)) }
    }

    /// Runs `write` against the enqueue-time database, or abandons it. A write that cannot be attributed
    /// to a profile is dropped where it would have committed rather than committing somewhere else, and
    /// says so on stderr — silently discarding durable state is how this class of bug hides.
    private static func withEnqueueTimeDatabase(_ database: EnqueueTimeDatabase, _ write: (String) -> Void) {
        switch database {
        case .resolved(let databasePath): write(databasePath)
        case .unresolved(let reason):
            FileHandle.standardError.write(
                Data("spaces: abandoned a queued terminal-session write; its profile could not be resolved when it was enqueued: \(reason)\n".utf8))
        }
    }

    /// Enqueue a durable write with no coalescing (unique mutations: expiry detaches, ownership transfer,
    /// the terminated payload). Runs on the serial persistence queue in enqueue (FIFO) order. The closure
    /// receives the database resolved at enqueue time and must pass it to the persistence call it makes.
    public func enqueueWrite(_ write: @escaping @Sendable (String) -> Void) {
        let database = Self.enqueueTimeDatabase()
        queue.async { Self.withEnqueueTimeDatabase(database) { write($0) } }
    }

    /// Enqueue work that touches no database but must observe the queue's FIFO order — the trailing
    /// durable-end notification fence, and the test gate that parks the queue. Kept apart from
    /// `enqueueWrite` so it neither asks for a database it will not use nor gets abandoned when a
    /// database write's profile cannot be resolved; its ordering guarantee is all it needs.
    public func enqueueOrderedWork(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

    /// Enqueue a latest-wins coalesced durable write for `key`: only the newest enqueue runs; a burst
    /// collapses to one write of the newest value (see `PersistenceCoalescingGate`). FIFO order across keys.
    public func enqueueCoalescedWrite(key: String, _ write: @escaping @Sendable (String) -> Void) {
        let generation = coalescingGate.nextGeneration(forKey: key)
        let gate = coalescingGate
        let database = Self.enqueueTimeDatabase()
        queue.async {
            guard gate.isLatest(generation, forKey: key) else { return }
            Self.withEnqueueTimeDatabase(database) { write($0) }
        }
    }

    /// Blocks the caller until every write enqueued so far has committed. Deadlock-free from the engine:
    /// persistence closures only ever hop BACK to the engine asynchronously (`Task { @TerminalEngineActor }`),
    /// never with a synchronous wait, so a blocked engine cannot cycle with the queue. Used only for the
    /// handoff/termination fences and test determinism — never on the per-keystroke path.
    public func drain() { queue.sync {} }

    /// Async drain for the handoff quiesce and daemon-shutdown paths: suspends (rather than blocking the
    /// engine) until the persistence queue is empty, so every mirror write is durable before the caller
    /// `execv`s or `exit`s.
    public func drainAsync() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }

    /// Runs one durable once-per-lifecycle mirror write on the serial queue: the launch configuration a core
    /// writes at create/handoff-resume, and the client upsert/attach/detach/ownership-transfer writes that
    /// mirror an attachment change the engine has already applied to its in-memory snapshot. Each is a unique
    /// mutation, so unlike the runtime-state chain nothing supersedes it; it retries IN PLACE (same policy and
    /// FIFO-slot semantics as `enqueueRuntimeStateWrite`) so a contended write lock delays the mirror instead
    /// of losing it, and so writes enqueued behind it — the attach that must land after its session row exists,
    /// the terminated payload — stay ordered behind it.
    ///
    /// `onFailure` runs on the persistence queue after the final attempt and is the core's cue that the
    /// in-memory snapshot it already applied no longer matches the durable mirror. It must hop back to the
    /// engine asynchronously (one-way rule), and the label decides its remedy there: an attachment write
    /// (client upsert/attach/detach/ownership-transfer) reconciles by dropping the cached snapshot and
    /// reseeding from committed truth, while the launch-configuration write terminates the core instead:
    /// every later mirror write validates against the `terminal_sessions` row that write creates, so a
    /// reconcile with no such row would just make every later write fail as `unknownSession`.
    ///
    /// An enqueue-time profile-resolution failure (`database` is `.unresolved`) counts as a final failure
    /// too, and also invokes `onFailure`: dropping the write silently, the way `withEnqueueTimeDatabase`
    /// does for the other enqueue methods, would leave the engine's in-memory authority permanently ahead
    /// of a mirror that never received the write, and for the launch-configuration label specifically would
    /// leave a live core registered with no `terminal_sessions` row at all. There is no retry to attempt:
    /// the resolution failure was captured once at enqueue time and cannot change inside this work item.
    public func enqueueLifecycleWrite(_ label: String, write: @escaping @Sendable (String) throws -> Void, onFailure: @escaping @Sendable () -> Void)
    {
        let maxAttempts = Self.writeMaxAttempts
        let retryDelay = writeRetryDelay
        let sleep = self.sleep
        let database = Self.enqueueTimeDatabase()
        queue.async {
            switch database {
            case .resolved(let databasePath):
                var attempt = 0
                while true {
                    do { try write(databasePath) } catch {
                        attempt += 1
                        guard attempt < maxAttempts else {
                            FileHandle.standardError.write(
                                Data("spaces: terminal-session \(label) write failed after \(maxAttempts) attempts: \(error)\n".utf8))
                            onFailure()
                            return
                        }
                        sleep(retryDelay)
                        continue
                    }
                    return
                }
            case .unresolved(let reason):
                FileHandle.standardError.write(
                    Data("spaces: terminal-session \(label) write abandoned; its profile could not be resolved when it was enqueued: \(reason)\n".utf8))
                onFailure()
            }
        }
    }

    /// Runs one durable runtime-state write on the serial queue. On failure it retries IN PLACE inside the
    /// single queued work item — looping up to `writeMaxAttempts` with the injected `sleep`
    /// back-off (real `Thread.sleep` in production, a virtualized wait in tests) between attempts — rather
    /// than re-enqueuing. Every state retries, not just `.exited`: the Linux headless
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
        let maxAttempts = Self.writeMaxAttempts
        let retryDelay = writeRetryDelay
        let sleep = self.sleep
        let gate = coalescingGate
        let generation = gate.nextGeneration(forKey: key)
        let database = Self.enqueueTimeDatabase()
        queue.async {
            Self.withEnqueueTimeDatabase(database) { databasePath in
                var attempt = 0
                while true {
                    guard gate.isLatest(generation, forKey: key) else { return }
                    do { try TerminalSessionPersistence.writeRuntimeState(state, paths: paths, databasePath: databasePath) } catch {
                        attempt += 1
                        guard attempt < maxAttempts else { return }
                        sleep(retryDelay)
                        continue
                    }
                    onPersisted(state, writeAt)
                    return
                }
            }
        }
    }
}
