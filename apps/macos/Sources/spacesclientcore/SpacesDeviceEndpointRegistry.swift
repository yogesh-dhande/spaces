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

    /// The shared resolver for `device`, created on first use from that record's candidates and proven
    /// address, and reconciled against the *stored* record on every later call.
    ///
    /// `device` names which resolver is wanted; it does not decide where that resolver dials. Callers
    /// hold their record for wildly different spans — a CLI command reads one and uses it once, while a
    /// terminal pane's model captures one at creation and passes the same value to every stream
    /// reconnect for the life of the pane — so a caller's copy is not evidence of anything except that
    /// the device existed when it was read. Trusting it would let the longest-lived holder narrow the
    /// shared resolver back to its oldest list on every reconnect, undoing every address learned since.
    /// The client database is the authority instead: one row, written by the merge and by pairing, read
    /// fresh here.
    ///
    /// `certificateFingerprint` is the identity to pin, which the caller has already resolved (the local
    /// device's fingerprint can be refreshed by a re-bootstrap, so it is not always the one still
    /// sitting in the passed record).
    public static func resolver(for device: SpacesPairedDeviceRecord, certificateFingerprint: String) -> SpacesDeviceEndpointResolver {
        resolver(for: device, certificateFingerprint: certificateFingerprint, database: nil)
    }

    /// The lookup above, against a specific database. `database` is nil everywhere in product code
    /// except the advertised-host merge, which already holds the connection it just wrote through and
    /// must reconcile against that same store rather than the process default.
    static func resolver(for device: SpacesPairedDeviceRecord, certificateFingerprint: String, database: SpacesClientDatabase?)
        -> SpacesDeviceEndpointResolver
    { storage.resolver(for: device, certificateFingerprint: certificateFingerprint, database: database) }

    /// Hands the resolver the candidate list from a freshly stored record, so an address learned after
    /// the resolver was built (the advertised-host merge) is dialable without waiting for a relaunch.
    public static func refresh(record: SpacesPairedDeviceRecord) { storage.refresh(record: record) }

    /// Drops what every resolver learned about where its device is — the cached winner and the
    /// candidates its stream has recently failed on. Called when this client's own network path changes:
    /// both facts were learned on a network this client may have just left, and nothing else invalidates
    /// them until a connection actually breaks, which on a silently dead path costs a full connect
    /// timeout first.
    public static func resetAllForNetworkChange() { storage.resetAllForNetworkChange() }

    /// Drops every resolver, so one test's proven addresses and candidate lists cannot leak into the
    /// next. Never called from product code.
    static func resetForTesting() { storage.resetForTesting() }

    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var resolvers: [String: SpacesDeviceEndpointResolver] = [:]

        func resolver(for device: SpacesPairedDeviceRecord, certificateFingerprint: String, database: SpacesClientDatabase?)
            -> SpacesDeviceEndpointResolver
        {
            let key = Self.key(certificateFingerprint: certificateFingerprint, port: device.port)
            lock.lock()
            if let existing = resolvers[key] {
                lock.unlock()
                // Reconciled against the stored row rather than the caller's copy of it, so that a
                // long-lived holder replaying an old record cannot narrow the shared resolver (see the
                // public entry point). A row that is genuinely gone leaves the resolver's list untouched:
                // the device was deleted or re-paired under a new identity, so whatever this connection is
                // about to attempt fails on its own terms and reports that, which is a far better answer
                // than a resolver silently emptied of every address it had.
                //
                // The cached winner is deliberately not re-seeded from the stored `active_host`: that
                // column is written *by* the resolver, so the live value is never staler than the stored
                // one, and re-seeding it here would silently undo `resetAllForNetworkChange`, whose whole
                // point is that the proven address is now suspect. The construction-time invariant that a
                // cached winner must be a member of the candidate list is preserved, because `updateHosts`
                // drops one that is not.
                if let stored = Self.storedRecord(deviceID: device.id, database: database) { existing.updateHosts(stored.hosts) }
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

        func resetAllForNetworkChange() {
            lock.lock()
            let current = Array(resolvers.values)
            lock.unlock()
            // Reset outside the registry lock: each resolver takes its own lock, and a caller already
            // inside one asking for a resolver would otherwise deadlock against this.
            for resolver in current { resolver.resetForNetworkChange() }
        }

        /// The device's row as stored, or nil when it no longer has one. A failed read is indistinguishable
        /// from a missing row on purpose: both mean this call has nothing authoritative to reconcile
        /// against, and the resolver keeps what it has rather than being narrowed on a guess.
        private static func storedRecord(deviceID: String, database: SpacesClientDatabase?) -> SpacesPairedDeviceRecord? {
            if let database { return try? database.pairedDevice(id: deviceID) }
            return try? SpacesClientDatabase.withDefaultDatabase { try $0.pairedDevice(id: deviceID) }
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
