import Foundation
import Security

struct SpacesMobilePairedDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    /// Ordered candidate daemon addresses, most-preferred first. See
    /// `SpacesMobileConnectionSettings.hosts` for the ordering contract.
    var hosts: [String]
    var port: Int
    var certificateFingerprint: String
    var createdAt: String
    var updatedAt: String
    var lastSelectedAt: String?
    /// The candidate that most recently connected successfully. This is a cache/hint, not
    /// authority: `recordActiveHost` only ever sets it to a value already present in `hosts`, and
    /// the connect path always re-validates it against `hosts` before use. Clearing it (e.g. via
    /// `clearActiveHosts`) just means the next connect attempt re-evaluates from the top of `hosts`.
    var activeHost: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case hosts
        /// Pre-multi-address key, read-only. `encode(to:)` never writes it.
        case legacyHost = "host"
        case port
        case certificateFingerprint
        case createdAt
        case updatedAt
        case lastSelectedAt
        case activeHost
    }

    init(
        id: String, name: String, hosts: [String], port: Int, certificateFingerprint: String, createdAt: String, updatedAt: String,
        lastSelectedAt: String?, activeHost: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.port = port
        self.certificateFingerprint = certificateFingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSelectedAt = lastSelectedAt
        self.activeHost = activeHost
    }

    // Records are stored as JSON in UserDefaults (`saveDevices`/`loadDevices`); a failed decode of
    // even one array element drops every paired device. Tolerate a record written by a pre-multi-
    // address build (single `host`, no `activeHost`) the same way `SpacesMobileConnectionSettings`
    // does, so an older local store keeps loading.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let decodedHosts = try container.decodeIfPresent([String].self, forKey: .hosts) {
            hosts = decodedHosts
        } else if let legacyHost = try container.decodeIfPresent(String.self, forKey: .legacyHost) {
            hosts = [legacyHost]
        } else {
            hosts = []
        }
        port = try container.decode(Int.self, forKey: .port)
        certificateFingerprint = try container.decode(String.self, forKey: .certificateFingerprint)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        lastSelectedAt = try container.decodeIfPresent(String.self, forKey: .lastSelectedAt)
        activeHost = try container.decodeIfPresent(String.self, forKey: .activeHost)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(port, forKey: .port)
        try container.encode(certificateFingerprint, forKey: .certificateFingerprint)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(lastSelectedAt, forKey: .lastSelectedAt)
        try container.encodeIfPresent(activeHost, forKey: .activeHost)
    }
}

struct SpacesMobileDeviceStoreState: Equatable, Sendable {
    var devices: [SpacesMobilePairedDeviceRecord]
    var activeDeviceID: String?
    var settings: SpacesMobileConnectionSettings
}

enum SpacesMobileDeviceStore {
    private static let devicesKey = "spaces.mobile.paired-devices"
    private static let activeDeviceKey = "spaces.mobile.active-device-id"
    private static let keychainService = "dev.usespaces.spacesmobile.device"

    #if DEBUG
        static func applyDebugSeed(environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard let rawSeed = environment["SPACES_MOBILE_TEST_DEVICE_SEED_JSON"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSeed.isEmpty,
                let data = rawSeed.data(using: .utf8), let seed = try? JSONDecoder().decode(DebugDeviceSeed.self, from: data)
            else { return }

            let now = ISO8601DateFormatter().string(from: Date())
            let records: [SpacesMobilePairedDeviceRecord] = seed.devices.compactMap { seededDevice in
                let host = seededDevice.host.trimmingCharacters(in: .whitespacesAndNewlines)
                let fingerprint = seededDevice.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                let authToken = seededDevice.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, (1...65_535).contains(seededDevice.port), !fingerprint.isEmpty, !authToken.isEmpty else { return nil }

                let id = seededDevice.id?.nilIfBlank ?? deviceID(certificateFingerprint: fingerprint, port: seededDevice.port)
                saveSecret(authToken, deviceID: id, kind: .authToken)
                return SpacesMobilePairedDeviceRecord(
                    id: id, name: seededDevice.name.nilIfBlank ?? host, hosts: [host], port: seededDevice.port, certificateFingerprint: fingerprint,
                    createdAt: seededDevice.createdAt ?? now, updatedAt: seededDevice.updatedAt ?? now,
                    lastSelectedAt: seededDevice.lastSelectedAt ?? now)
            }
            guard !records.isEmpty else { return }

            saveDevices(records)
            let activeID =
                seed.activeDeviceID?.nilIfBlank.flatMap { requestedID in records.contains(where: { $0.id == requestedID }) ? requestedID : nil }
                ?? records.first?.id
            if let activeID { UserDefaults.standard.set(activeID, forKey: activeDeviceKey) }
        }

        private struct DebugDeviceSeed: Decodable {
            var activeDeviceID: String?
            var devices: [DebugDeviceSeedRecord]
        }

        // The `host` key stays singular (not `hosts`) even though the record it seeds now stores an
        // array: e2e harnesses (apps/macos/Tests/e2e_mobile.sh, run_mobile_terminal_demo.sh) write
        // this JSON shape and must not need to change. `applyDebugSeed` above wraps it as `[host]`.
        private struct DebugDeviceSeedRecord: Decodable {
            var id: String?
            var name: String
            var host: String
            var port: Int
            var certificateFingerprint: String
            var authToken: String
            var createdAt: String?
            var updatedAt: String?
            var lastSelectedAt: String?
        }
    #endif

    static func load(fallbackSettings: SpacesMobileConnectionSettings) -> SpacesMobileDeviceStoreState {
        var devices = loadDevices()
        var activeDeviceID = UserDefaults.standard.string(forKey: activeDeviceKey)?.nilIfBlank
        var settings = fallbackSettings

        if devices.isEmpty, fallbackSettings.isPaired {
            let record = record(from: fallbackSettings, name: fallbackSettings.primaryHost)
            devices = [record]
            activeDeviceID = record.id
            saveSecret(fallbackSettings.authToken, deviceID: record.id, kind: .authToken)
            saveDevices(devices)
            UserDefaults.standard.set(record.id, forKey: activeDeviceKey)
        }

        if let active = activeDeviceID, !devices.contains(where: { $0.id == active }) {
            activeDeviceID = devices.first?.id
        } else if activeDeviceID == nil {
            activeDeviceID = devices.first?.id
        }
        if let activeDeviceID {
            UserDefaults.standard.set(activeDeviceID, forKey: activeDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeDeviceKey)
        }
        if let activeDeviceID, let active = devices.first(where: { $0.id == activeDeviceID }) {
            settings = Self.settings(from: active, installationID: fallbackSettings.installationID)
        } else if !fallbackSettings.isPaired {
            settings.authToken = ""
            settings.certificateFingerprint = ""
        }

        return SpacesMobileDeviceStoreState(devices: devices, activeDeviceID: activeDeviceID, settings: settings)
    }

    @discardableResult static func upsert(settings: SpacesMobileConnectionSettings, name: String) -> SpacesMobileDeviceStoreState {
        let now = ISO8601DateFormatter().string(from: Date())
        var devices = loadDevices()
        var record = record(from: settings, name: name)
        let fingerprint = record.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Match an existing paired device by certificate fingerprint, not the derived id: `hosts` (and
        // therefore the id, which no longer folds the address in — see `deviceID` below) can differ
        // across a re-pair, e.g. a QR rescan that adds the Tailscale candidate to an already-paired
        // Mac. Reusing the existing record's id keeps its Keychain auth token and any browser-proxy
        // routes already keyed on that id, so the rescan upgrades the row in place instead of the
        // device appearing a second time.
        // A brand-new record already carries `now` for all three timestamps from `record(from:)`; only a
        // match needs rewriting, to keep the original `createdAt` and carry a still-valid `activeHost`
        // forward so a rescan does not throw away a known-good address.
        if let existing = devices.first(where: {
            $0.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == fingerprint
        }) {
            record = SpacesMobilePairedDeviceRecord(
                id: existing.id, name: record.name, hosts: record.hosts, port: record.port, certificateFingerprint: record.certificateFingerprint,
                createdAt: existing.createdAt, updatedAt: now, lastSelectedAt: now,
                activeHost: existing.activeHost.flatMap { record.hosts.contains($0) ? $0 : nil })
        }
        devices.removeAll { $0.id == record.id }
        devices.insert(record, at: 0)
        saveSecret(settings.authToken, deviceID: record.id, kind: .authToken)
        saveDevices(devices)
        UserDefaults.standard.set(record.id, forKey: activeDeviceKey)
        return load(fallbackSettings: settings)
    }

    @discardableResult static func rename(deviceID: String, name: String, fallbackSettings: SpacesMobileConnectionSettings)
        -> SpacesMobileDeviceStoreState
    {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var devices = loadDevices()
        if !trimmed.isEmpty, let index = devices.firstIndex(where: { $0.id == deviceID }) {
            devices[index].name = trimmed
            devices[index].updatedAt = ISO8601DateFormatter().string(from: Date())
            saveDevices(devices)
        }
        return load(fallbackSettings: fallbackSettings)
    }

    static func select(deviceID: String, installationID: String) -> SpacesMobileDeviceStoreState? {
        var devices = loadDevices()
        guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return nil }
        devices[index].lastSelectedAt = ISO8601DateFormatter().string(from: Date())
        saveDevices(devices)
        UserDefaults.standard.set(deviceID, forKey: activeDeviceKey)
        return load(fallbackSettings: settings(from: devices[index], installationID: installationID))
    }

    static func remove(deviceID: String, fallbackSettings: SpacesMobileConnectionSettings) -> SpacesMobileDeviceStoreState {
        let devices = loadDevices().filter { $0.id != deviceID }
        deleteSecret(deviceID: deviceID, kind: .authToken)
        let activeDeviceID = UserDefaults.standard.string(forKey: activeDeviceKey)
        if activeDeviceID == deviceID {
            if let firstDeviceID = devices.first?.id {
                UserDefaults.standard.set(firstDeviceID, forKey: activeDeviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeDeviceKey)
            }
        }
        saveDevices(devices)
        var fallback = fallbackSettings
        if devices.isEmpty {
            fallback.authToken = ""
            fallback.certificateFingerprint = ""
        }
        return load(fallbackSettings: fallback)
    }

    /// Reads a paired device's Device API auth token from the Keychain, keyed by the same device ID
    /// the browser routing table carries. The browser proxy dialer authenticates its raw-byte service
    /// tunnel with this token, so it needs to look the secret up out of band from the settings flow.
    static func authToken(deviceID: String) -> String? { secret(deviceID: deviceID, kind: .authToken) }

    /// Persists the candidate that most recently connected successfully, so the next
    /// `settings(from:)` read gets a warm start. Called by `SpacesDeviceEndpointResolver` once it
    /// learns which address answered. Keyed by certificate fingerprint rather than device id: the
    /// resolver validates a candidate by its pinned certificate, not by looking up a device row, so
    /// the fingerprint is the only identifier it actually has on hand. Matches fingerprints the same
    /// trimmed+lowercased way `upsert` does. Ignores `host` values that are not already one of the
    /// matched record's `hosts` rather than inventing a candidate — `activeHost` is only ever a member
    /// of `hosts`. Every connection reports its winner, so this no-ops when the value is unchanged
    /// rather than re-encoding the whole device list into `UserDefaults` on each reconnect.
    static func recordActiveHost(_ host: String, certificateFingerprint: String) {
        let fingerprint = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var devices = loadDevices()
        guard
            let index = devices.firstIndex(where: {
                $0.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == fingerprint
            }), devices[index].hosts.contains(host), devices[index].activeHost != host
        else { return }
        devices[index].activeHost = host
        saveDevices(devices)
    }

    /// Backfills a paired device's `hosts` from the addresses its daemon reports it is reachable at
    /// (`TerminalServiceDaemonStatus.deviceAPIAddresses`). This is how a device paired before its Mac
    /// ever had Tailscale silently gains the tailnet fallback the moment the Mac gets one — with no
    /// rescan required, since the daemon now advertises its own live addresses on every connection.
    ///
    /// No-ops when `hosts` is empty: an empty list means the daemon reported nothing (it predates this
    /// field, or this call raced a path that could not enumerate interfaces), never that the daemon has
    /// no addresses — see `TerminalServiceDaemonStatus.deviceAPIAddresses`. Also no-ops when `hosts`
    /// already equals the matched record's `hosts`, the common steady-state case, to avoid re-encoding
    /// the whole device list into `UserDefaults` on every overview fetch.
    ///
    /// The daemon's order replaces the record's order outright (rather than merging) because the daemon
    /// is authoritative about its own reachability and its order already encodes LAN-first preference
    /// exactly like a pairing link would. `activeHost` survives only if it is still a member of the new
    /// list; otherwise the next connect re-evaluates from the top, same as `clearActiveHosts`. Matches
    /// fingerprints the same trimmed+lowercased way `upsert`/`recordActiveHost` do.
    static func mergeAdvertisedHosts(_ hosts: [String], certificateFingerprint: String) {
        guard !hosts.isEmpty else { return }
        let fingerprint = certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var devices = loadDevices()
        guard
            let index = devices.firstIndex(where: {
                $0.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == fingerprint
            }), devices[index].hosts != hosts
        else { return }
        devices[index].hosts = hosts
        if let activeHost = devices[index].activeHost, !hosts.contains(activeHost) {
            devices[index].activeHost = nil
        }
        saveDevices(devices)
    }

    /// Clears the cached active host on every paired device, so the next connect attempt on each
    /// re-evaluates from the top of its `hosts` list instead of trusting a possibly-stale cache (e.g.
    /// after the app returns to the foreground on a different network).
    static func clearActiveHosts() {
        var devices = loadDevices()
        guard devices.contains(where: { $0.activeHost != nil }) else { return }
        for index in devices.indices { devices[index].activeHost = nil }
        saveDevices(devices)
    }

    private static func loadDevices() -> [SpacesMobilePairedDeviceRecord] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
            let decoded = try? JSONDecoder().decode([SpacesMobilePairedDeviceRecord].self, from: data)
        else { return [] }
        return decoded.sorted { ($0.lastSelectedAt ?? $0.updatedAt) > ($1.lastSelectedAt ?? $1.updatedAt) }
    }

    private static func saveDevices(_ devices: [SpacesMobilePairedDeviceRecord]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: devicesKey)
    }

    private static func record(from settings: SpacesMobileConnectionSettings, name: String) -> SpacesMobilePairedDeviceRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        return SpacesMobilePairedDeviceRecord(
            id: deviceID(certificateFingerprint: settings.certificateFingerprint, port: settings.port), name: name,
            hosts: settings.trimmedHosts, port: settings.port, certificateFingerprint: settings.certificateFingerprint, createdAt: now,
            updatedAt: now, lastSelectedAt: now)
    }

    private static func settings(from device: SpacesMobilePairedDeviceRecord, installationID: String) -> SpacesMobileConnectionSettings {
        var settings = SpacesMobileConnectionSettings()
        // Put the device's last-known-good address first when it's still one of the candidates, so
        // the connect path gets a warm start for free: `SpacesDeviceAPIClient` reads `primaryHost`
        // today, and the follow-up candidate-walking transport will read `hosts` in order.
        if let activeHost = device.activeHost, device.hosts.contains(activeHost) {
            settings.hosts = [activeHost] + device.hosts.filter { $0 != activeHost }
        } else {
            settings.hosts = device.hosts
        }
        settings.port = device.port
        settings.certificateFingerprint = device.certificateFingerprint
        settings.authToken = secret(deviceID: device.id, kind: .authToken) ?? ""
        settings.installationID = installationID
        return settings
    }

    /// Slugs to `"<fingerprint>|<port>"`, deliberately excluding the address. The auth token
    /// (`saveSecret`/`secret`, keyed `"<deviceID>.authToken"`) and `BrowserProxyRouteTarget.deviceID`
    /// both key off this id; if it moved whenever a client switched from the LAN address to the
    /// Tailscale address, the device would appear to be a different device and lose its stored token.
    private static func deviceID(certificateFingerprint: String, port: Int) -> String {
        let source = "\(certificateFingerprint)|\(port)".lowercased()
        let slug = source.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(
            in: CharacterSet(charactersIn: "-"))
        return "device-\(slug.prefix(48))"
    }

    private enum SecretKind: String { case authToken }

    private static func saveSecret(_ value: String, deviceID: String, kind: SecretKind) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let query = keychainQuery(deviceID: deviceID, kind: kind)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(trimmed.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func secret(deviceID: String, kind: SecretKind) -> String? {
        var query = keychainQuery(deviceID: deviceID, kind: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func deleteSecret(deviceID: String, kind: SecretKind) {
        SecItemDelete(keychainQuery(deviceID: deviceID, kind: kind) as CFDictionary)
    }

    private static func keychainQuery(deviceID: String, kind: SecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(deviceID).\(kind.rawValue)",
        ]
    }
}

extension String {
    fileprivate var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
