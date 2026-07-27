import Dispatch
import Foundation
import workspacecore

/// Owns one long-lived `SQLiteStore` for a single daemon reconcile loop, and is the only
/// execution context that ever touches it.
///
/// ## Why the connection is long-lived
/// The reconcile loops that use this are driven by notifications that fire as fast as terminal
/// output and database writes arrive. Opening a connection per pass makes SQLite build the WAL
/// index/shared-memory mapping on every open and run a full WAL checkpoint plus `fsync` on every
/// close, so ordinary terminal activity turned into sustained disk I/O inside `spacesd`. One
/// connection held for the loop's lifetime pays both costs once.
///
/// ## Why a dedicated serial queue owns it
/// `SQLiteStore` is a plain, non-`Sendable` class, so a shared connection must live in exactly one
/// isolation domain. `queue` is that domain: it is the only place `store` is created, read, or
/// released, and passes run one at a time on it, so the connection can never be touched from two
/// contexts concurrently. The reconcile body is supplied once at construction rather than per call
/// so the non-`Sendable` store never has to cross an isolation boundary. `.utility` matches the
/// priority the previous per-pass detached tasks ran at: reconciles are background housekeeping and
/// must not compete with terminal I/O.
///
/// ## Why reuse is safe across passes
/// Each pass commits (or rolls back) before it returns, so no transaction is held open between
/// passes: the connection never pins a WAL read mark and never blocks another process's writes. A
/// WAL reader re-reads the WAL header when it begins a statement, so a reused connection observes
/// commits made meanwhile by the app, the CLI, and other daemon connections exactly as a fresh one
/// would.
///
/// ## Why close is terminal
/// The connection's release is also its final WAL checkpoint, so it has to be final in fact: the
/// daemon re-execs itself across updates, and a connection re-opened after the owning service
/// stopped would still be holding the database when the replacement daemon starts. `close()`
/// therefore latches, and a pass that lands afterwards does nothing at all rather than opening a
/// connection nobody will ever close. `close()` is also async and does not return until the release has
/// actually happened, so a caller can establish the guarantee rather than inherit it from the accident of
/// its own shutdown ordering.
///
/// `@unchecked Sendable` is sound because the only mutable state is `store` and `isClosed`, both
/// confined to `queue`; everything else is immutable.
final class DaemonReconcileStore: @unchecked Sendable {
    private let databasePath: String
    private let queue: DispatchQueue
    private let pass: (SQLiteStore) throws -> Void
    /// Queue-confined. Opened on the first pass and reused by every pass after it.
    private var store: SQLiteStore?
    /// Queue-confined. Latched by `close()` and never cleared.
    private var isClosed = false

    init(label: String, databasePath: String, pass: @escaping (SQLiteStore) throws -> Void) {
        self.databasePath = databasePath
        self.pass = pass
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Runs one reconcile pass on the owning queue and suspends the caller until it finishes,
    /// rethrowing whatever the pass threw. Awaiting keeps the caller's coalescing (one pass in
    /// flight plus at most one trailing re-run) accurate.
    ///
    /// After `close()` this succeeds without running the pass. A pass submitted during shutdown is
    /// ordinary — the owning services coalesce on the main actor while passes run here, and a
    /// notification already queued for delivery can reach a service that has just stopped — so it is
    /// neither an error to report nor a reason to reopen the database; there is simply nothing left
    /// to reconcile on a service that has stopped.
    func runPass() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !self.isClosed else {
                    continuation.resume()
                    return
                }
                do {
                    try self.pass(try self.openedStore())
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Permanently releases the connection so its final WAL checkpoint happens when the owning service
    /// stops rather than only at process exit, and does not return until that has happened. The release
    /// runs on the owning queue, so it cannot race a pass, and it is idempotent: a second call finds the
    /// connection already released, so the checkpoint happens exactly once.
    ///
    /// Waiting for it is the point. The daemon hands the database to a replacement across a re-exec, so
    /// "the connection is released" has to be a fact a caller can establish, not merely the likely outcome
    /// of a queue draining faster than the rest of shutdown. `close()` returning is that fact.
    ///
    /// The wait is a SUSPENSION, never a blocked thread, and that is what makes it safe. Both owners stop
    /// on the main actor, and a reconcile pass ahead of this close reaches `WorkspaceOrchestrator`'s
    /// process-wide built-in-terminal terminator, which synchronously enters the terminal engine actor —
    /// which may in turn legally hop synchronously back to the main queue (the one-way rule documented on
    /// `TerminalEngineActor`). Blocking the main thread here, with `queue.sync`, would close that ring:
    /// main waits on this queue, the pass on it waits on the engine, and the engine waits on main.
    /// Awaiting a continuation leaves the main actor free instead, so the engine's hop to main runs, the
    /// pass ahead finishes, the release happens, and this call resumes.
    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.isClosed = true
                self.store = nil
                continuation.resume()
            }
        }
    }

    private func openedStore() throws -> SQLiteStore {
        if let store { return store }
        let opened = try SQLiteStore(path: databasePath)
        store = opened
        return opened
    }
}
