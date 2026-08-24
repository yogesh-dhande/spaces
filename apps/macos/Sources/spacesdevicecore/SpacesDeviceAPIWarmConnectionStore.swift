import Foundation
import spacesterminalcore

/// The idle pinned-TLS connections the raced request path keeps warm: at most one per Device API
/// endpoint, parked by the request that finished with it and taken by the next one.
///
/// A Device API request is a single round trip on a connection whose handshake costs a full TLS
/// negotiation plus a certificate trust evaluation, and the command path issues those continuously —
/// the sidebar re-reads the local daemon's overview on every reload, which a streaming terminal drives
/// several times a second. Dialing per request pays that handshake every time, on both sides, forever.
/// Parking the connection instead makes the steady state one connection per endpoint, which is what the
/// stream path has always had.
///
/// Keyed by pinned certificate fingerprint and port, matching `SpacesDeviceEndpointRegistry`'s key in
/// `spacesclientcore`: that pair is the endpoint a connection is established to, so a daemon that
/// rotated its identity or moved to a different port never sees a connection parked under the old one.
public final class SpacesDeviceAPIWarmConnectionStore: @unchecked Sendable {
    /// The store every request client uses unless a test hands it its own.
    public static let shared = SpacesDeviceAPIWarmConnectionStore()

    /// A parked connection and the candidate address it is established on, so a request that fails on
    /// it can report that address to the resolver rather than guessing which candidate broke.
    struct Warm {
        let connection: any SpacesPinnedTLSLineConnection
        let host: String
    }

    /// How long a connection may sit parked before it is dropped unused. The Linux Device API server
    /// closes an idle request socket after 120 seconds, so a longer-parked connection is assumed gone;
    /// this is the same margin `SpacesDeviceAPIRequestSessionClient` reconnects on.
    private static let defaultMaximumIdleInterval: TimeInterval = 90

    private struct Entry {
        let connection: any SpacesPinnedTLSLineConnection
        let host: String
        let parkedAtUptime: TimeInterval
    }

    private let maximumIdleInterval: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Bumped by `discardAll`. A request reads it before it takes or dials, and `park` refuses a
    /// connection whose generation is behind: `discardAll` cannot see a connection that is out with a
    /// request at that moment, and parking it afterwards would hand the next request a socket from the
    /// network this client has left, which is what the discard exists to prevent.
    private var generation = 0

    /// The store's current discard generation, to hand back to `park`.
    var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    init(
        maximumIdleInterval: TimeInterval = SpacesDeviceAPIWarmConnectionStore.defaultMaximumIdleInterval,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.maximumIdleInterval = maximumIdleInterval
        self.uptime = uptime
    }

    /// The endpoint's parked connection, removed from the store, or nil when none is parked or the
    /// parked one has been idle long enough that the daemon may already have closed it. A taken
    /// connection belongs to the caller: it is parked again only if that request completes on it.
    func take(endpoint: String) -> Warm? {
        lock.lock()
        guard let entry = entries.removeValue(forKey: endpoint) else {
            lock.unlock()
            return nil
        }
        let idleSeconds = uptime() - entry.parkedAtUptime
        lock.unlock()
        guard idleSeconds < maximumIdleInterval else {
            entry.connection.cancel()
            return nil
        }
        return Warm(connection: entry.connection, host: entry.host)
    }

    /// Parks a connection the daemon just answered on. Only one connection is kept per endpoint: a
    /// second one arriving from a concurrent request replaces the parked one, which is cancelled rather
    /// than left open, so concurrency raises the connection count only while the requests overlap.
    ///
    /// Parking also sweeps every other endpoint's entry that has sat past the idle limit. Expiry is
    /// otherwise only checked by `take`, so an endpoint that is never asked for again (a daemon that
    /// rebound its port, a device re-paired under a rotated identity, a removed device) would keep its
    /// socket open on both sides for the life of the process; any endpoint's traffic closes those.
    func park(_ connection: any SpacesPinnedTLSLineConnection, host: String, endpoint: String, generation: Int) {
        let now = uptime()
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            connection.cancel()
            return
        }
        var closing = [any SpacesPinnedTLSLineConnection]()
        if let replaced = entries[endpoint] { closing.append(replaced.connection) }
        for (key, entry) in entries where key != endpoint && now - entry.parkedAtUptime >= maximumIdleInterval {
            closing.append(entry.connection)
            entries.removeValue(forKey: key)
        }
        entries[endpoint] = Entry(connection: connection, host: host, parkedAtUptime: now)
        lock.unlock()
        for stale in closing { stale.cancel() }
    }

    /// Drops every parked connection. Called when this client's network path changes: a connection
    /// parked on the network this client just left is dead, and the first request to take it would pay a
    /// full timeout discovering that on a path that blackholes rather than refuses.
    public func discardAll() {
        lock.lock()
        generation += 1
        let parked = entries.values.map(\.connection)
        entries.removeAll()
        lock.unlock()
        for connection in parked { connection.cancel() }
    }

    /// The key an endpoint's connections are parked under.
    static func endpointKey(certificateFingerprint: String, port: Int) -> String {
        "\(certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(port)"
    }
}
