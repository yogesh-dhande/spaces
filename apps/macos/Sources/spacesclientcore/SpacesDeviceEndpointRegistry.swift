import Foundation
import spacesdevicecore

/// The process-wide owner of one `SpacesDeviceEndpointResolver` per paired device.
///
/// A device's command path (one-shot requests, the persistent request session) and its stream paths
/// (the overview subscription, a terminal-state subscription) are built independently and at different
/// times, but they must converge on the same address: a request that fails over from the LAN address to
/// the tailnet address has to steer the next stream reconnect, and a stream that rotates off a dead
/// address has to steer the next request. Sharing one resolver per device is what makes that true
/// without either path knowing about the other.
///
/// Keyed by pinned certificate fingerprint and port rather than by device id, because that pair is what
/// the resolver actually dials: a daemon that rotates its identity or moves to a different port is a
/// different endpoint and gets its own resolver, while the record's id can be re-used across a re-pair.
public enum SpacesDeviceEndpointRegistry {
    private static let storage = Storage()

    /// The shared resolver for `device`, created on first use from the record's stored candidates and
    /// its proven address, and reconciled with the passed record's candidates on every later call.
    /// `certificateFingerprint` is the identity to pin, which the caller has already resolved (the local
    /// device's fingerprint can be refreshed by a re-bootstrap, so it is not always the one still
    /// sitting in the passed record).
    public static func resolver(for device: SpacesPairedDeviceRecord, certificateFingerprint: String) -> SpacesDeviceEndpointResolver {
        storage.resolver(for: device, certificateFingerprint: certificateFingerprint)
    }

    /// Hands the resolver the candidate list from a freshly stored record, so an address learned after
    /// the resolver was built (the advertised-host merge) is dialable without waiting for a relaunch.
    public static func refresh(record: SpacesPairedDeviceRecord) { storage.refresh(record: record) }

    /// Forgets every resolver's cached winner, so the next connect re-walks that device's candidates
    /// from the top instead of going straight back to the address it last proved. Called when this
    /// client's own network path changes: the address proven a moment ago was proven on a network this
    /// client may have just left, and nothing else invalidates it until a connection on it actually
    /// breaks — which on a silently dead path costs a full connect timeout first.
    public static func clearAllCachedWinners() { storage.clearAllCachedWinners() }

    /// Drops every resolver, so one test's proven addresses and candidate lists cannot leak into the
    /// next. Never called from product code.
    static func resetForTesting() { storage.resetForTesting() }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var resolvers: [String: SpacesDeviceEndpointResolver] = [:]

        func resolver(for device: SpacesPairedDeviceRecord, certificateFingerprint: String) -> SpacesDeviceEndpointResolver {
            let key = Self.key(certificateFingerprint: certificateFingerprint, port: device.port)
            lock.lock()
            if let existing = resolvers[key] {
                lock.unlock()
                // The caller just read this record, so its candidates can be newer than the ones the
                // resolver was built with: a re-pair rewrites them, and so does another process's write to
                // the shared client database (the CLI and the app run against one profile). Without this
                // reconcile the live resolver keeps dialing the list it was constructed with until the app
                // relaunches. The resolver's own cached winner is deliberately not re-seeded from the
                // record's `active_host`: that column is written *by* the resolver, so the live value is
                // never staler than the stored one, and re-seeding it here would silently undo
                // `clearAllCachedWinners`, whose whole point is that the proven address is now suspect.
                // The construction-time invariant that a cached winner must be a member of the candidate
                // list is preserved, because `updateHosts` drops one that is not.
                existing.updateHosts(device.hosts)
                return existing
            }
            let deviceID = device.id
            let created = SpacesDeviceEndpointResolver(
                hosts: device.hosts, port: device.port, certificateFingerprint: certificateFingerprint, activeHost: device.activeHost,
                onProvenHost: { host in Self.persist(deviceID: deviceID, host: host) })
            resolvers[key] = created
            lock.unlock()
            return created
        }

        func refresh(record: SpacesPairedDeviceRecord) {
            let key = Self.key(certificateFingerprint: record.certificateFingerprint, port: record.port)
            lock.lock()
            let existing = resolvers[key]
            lock.unlock()
            existing?.updateHosts(record.hosts)
        }

        func clearAllCachedWinners() {
            lock.lock()
            let current = Array(resolvers.values)
            lock.unlock()
            // Cleared outside the registry lock: each resolver takes its own lock, and a caller already
            // inside one asking for a resolver would otherwise deadlock against this.
            for resolver in current { resolver.clearCachedWinner() }
        }

        func resetForTesting() {
            lock.lock()
            resolvers.removeAll()
            lock.unlock()
        }

        /// Persists the address a connect just proved, so the next launch dials it first instead of
        /// re-racing every candidate. A failed write costs one race on the next launch and nothing else,
        /// so it is not worth failing a working connection over.
        private static func persist(deviceID: String, host: String) {
            try? SpacesClientDatabase.withDefaultDatabase { try $0.setActiveHost(deviceID: deviceID, host: host) }
        }

        private static func key(certificateFingerprint: String, port: Int) -> String {
            "\(certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(port)"
        }
    }
}
