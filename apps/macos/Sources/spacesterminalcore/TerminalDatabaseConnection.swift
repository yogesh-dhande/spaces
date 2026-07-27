import Dispatch
import Foundation
import spacesdatabase

/// Owns the process's connections to the terminal database — one for reads, one for writes — and is the
/// only execution context that ever touches either.
///
/// ## Why the connections are long-lived
/// Every terminal read and write funnels through `TerminalSessionPersistence`, and the daemon runs those
/// continuously: a 1 Hz runtime-state sweep per live session, a device-overview rebuild several times a
/// second, and a durable write behind every attach, lease touch and state change. Opening a connection
/// per call made each of them pay `sqlite3_open_v2`, three connection pragmas — the first of which
/// re-parses the whole schema — the migrator's `sqlite_master` and `migration_state` probes, and then a
/// close whose final WAL checkpoint copies the log back into the database and fsyncs it. That setup and
/// teardown dominated the actual statement by more than an order of magnitude, and it was paid on the
/// serial terminal-engine queue that also carries keystrokes. Connections held for the process's lifetime
/// pay it once. This is the same reasoning, and the same shape, as `DaemonReconcileStore` in spacesd.
///
/// ## Why reads and writes are separate connections
/// The terminal engine reads durable state inline — owner gating, stale-client liveness — and those reads
/// must never wait for a writer, because a writer can be stuck on the database's write lock for as long as
/// the busy timeout while another process holds it. WAL gives exactly that: a reader runs concurrently
/// with a writer, on its own connection. Serving both from one connection would have queued those engine
/// reads behind a blocked write and stalled the engine — the coupling the per-core persistence queue was
/// introduced to remove. Two connections keep the guarantee while still opening each of them once.
///
/// Writers share one connection and therefore serialize, which is what they already did on the database
/// file — through a busy-timeout retry loop that slept between attempts. Readers likewise share one
/// connection and serialize with each other, but only for the SQLite statement itself: a WAL read never
/// waits on the write lock, so that part of the lane is briefly held no matter how many readers are
/// queued behind it. That guarantee does NOT extend to whatever a caller's closure does with the row once
/// SQLite has returned it — decoding a value, resolving a path, walking a socket directory — because none
/// of that needs the connection, yet it still runs while the lane (and every other reader behind it) waits.
/// Every read below is written to return raw rows from the lane and do that work after leaving it, the
/// same shape `TerminalSessionCatalog.listLiveSessions` uses; a call that skips this coupling an unrelated
/// reader's stall to work that has nothing to do with SQLite is a bug in that call, not a cost this lane
/// is willing to accept.
///
/// ## Why a dedicated serial queue owns each connection
/// `SpacesSQLiteDatabase` wraps one `sqlite3` handle, and a transaction (`BEGIN IMMEDIATE` … `COMMIT`) is a
/// property of that handle rather than of a call. Two threads sharing one connection would interleave
/// their transactions — the second `BEGIN` fails outright, and a `COMMIT` from one thread would commit the
/// other's half-written unit of work. `SQLITE_OPEN_FULLMUTEX` prevents data races inside SQLite but says
/// nothing about transaction scope, so it is not on its own enough. Each lane's queue is the isolation
/// domain that is: it is the only place its connection is created, used, or released, and it runs one unit
/// of work at a time, so a transaction opened by a caller is always finished by that same caller before
/// the next one starts. Neither queue takes an explicit QoS, so `sync` donates the caller's priority and
/// terminal-engine work never waits behind background housekeeping at a fixed lower priority.
///
/// ## Why reuse is safe across calls and across processes
/// Each unit of work commits or rolls back before it returns, so no transaction is held open between
/// calls: neither connection ever pins a WAL read mark, and neither blocks the app, the CLI, or another
/// daemon connection from writing. A WAL reader re-reads the WAL index when it starts a statement, so a
/// reused connection observes other processes' commits — and the write lane's commits — exactly as a
/// freshly opened one would.
///
/// A connection is released as soon as a unit of work fails with a fault SQLite reported, so a fault that
/// outlives the statement cannot outlive the connection: recovering by opening again is a property a
/// connection per call had for free, and it is what makes the persistence queue's write retries work.
///
/// ## Why one entry per lane is the whole cache
/// A process serves exactly one profile — `SpacesProfile.current()` is fixed for a daemon's life, and the
/// explicit path deferred writes carry is that same profile's database resolved earlier. One connection
/// per lane therefore covers every production caller, and keying it on the resolved path keeps it honest:
/// a test that rebinds the profile gets the previous connection released (final checkpoint included) and a
/// new one opened, rather than silently reading the profile it has just left.
final class TerminalDatabaseConnection: @unchecked Sendable {
    static let shared = TerminalDatabaseConnection()

    private let readLane = Lane(label: "spaces.terminal.database.read")
    private let writeLane = Lane(label: "spaces.terminal.database.write")

    /// Runs one read against the read connection.
    func read<T>(path: String, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T { try readLane.run(path: path, body) }

    /// Runs one mutation as a single `BEGIN IMMEDIATE` transaction against the write connection. The
    /// transaction is opened here rather than by the caller so a mutation cannot be run on the read lane by
    /// omission — the only way to get a transaction is to ask for the lane that has one.
    func write<T>(path: String, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
        try writeLane.run(path: path) { database in try database.withImmediateTransaction { try body(database) } }
    }

    /// Releases both connections so their final WAL checkpoints happen at a moment of the caller's
    /// choosing rather than at process teardown — or, for the daemon's `execv` handoff, not at all.
    /// Idempotent, and deliberately not latched: the handoff has a failure path that resumes the daemon in
    /// place, and that daemon must be able to open the database again.
    func close() {
        readLane.close()
        writeLane.close()
    }

    /// Units of database work run since process start, across both lanes.
    ///
    /// This is the one counter kept for tests, and it exists because the cost it measures is a product
    /// guarantee rather than an implementation detail: listing sessions and sweeping an idle session must
    /// cost work proportional to the *live* sessions, not to every session the device has ever created, and
    /// no assertion about returned values can tell those two apart. Incrementing an `Int` already inside a
    /// lane's critical section is free next to the statement that follows it.
    var workUnitCount: Int { readLane.workUnitCount + writeLane.workUnitCount }

    /// One connection and the serial queue that owns it.
    private final class Lane: @unchecked Sendable {
        private let queue: DispatchQueue
        /// Queue-confined. The path `database` is open on, so a caller naming a different profile's
        /// database replaces it rather than being served the wrong one.
        private var openPath: String?
        /// Queue-confined. Opened on first use and reused by every unit of work after it.
        private var database: SpacesSQLiteDatabase?
        /// Queue-confined except for the test-facing read below, which is taken on the queue too.
        private var runCount = 0

        init(label: String) { queue = DispatchQueue(label: label) }

        var workUnitCount: Int { queue.sync { runCount } }

        func run<T>(path: String, _ body: (SpacesSQLiteDatabase) throws -> T) throws -> T {
            try queue.sync {
                runCount += 1
                let database = try openedDatabase(path: path)
                do { return try body(database) } catch {
                    // A fault SQLite itself reported can have left the connection unusable — the file under
                    // it replaced, its WAL index invalidated — and a connection kept after that would keep
                    // failing where a fresh one succeeds, turning a transient fault into a permanent one.
                    // A caller's own error (an unknown session, a value that would not decode) says nothing
                    // about the connection, so it keeps it.
                    if (error as NSError).domain == SpacesSQLiteDatabase.errorDomain { release() }
                    throw error
                }
            }
        }

        func close() { queue.sync { release() } }

        private func openedDatabase(path: String) throws -> SpacesSQLiteDatabase {
            if let database, openPath == path { return database }
            // Release the outgoing connection (and take its final checkpoint) before opening the next one,
            // so the two never overlap on different databases.
            release()
            let opened = try SpacesSQLiteDatabase(
                path: path,
                withMigrationAuthorization: { migration in try ProfileDatabaseMigrationGuard.withMigrationAuthorization(databasePath: path, migration)
                })
            database = opened
            openPath = path
            return opened
        }

        /// Queue-confined. Dropping the last reference is what closes the connection and takes its final
        /// WAL checkpoint.
        private func release() {
            database = nil
            openPath = nil
        }
    }
}
