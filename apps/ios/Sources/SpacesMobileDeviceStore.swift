import Foundation
import Security

struct SpacesMobilePairedDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var certificateFingerprint: String
    var createdAt: String
    var updatedAt: String
    var lastSelectedAt: String?
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
            guard let rawSeed = environment["SPACES_MOBILE_TEST_DEVICE_SEED_JSON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawSeed.isEmpty,
                  let data = rawSeed.data(using: .utf8),
                  let seed = try? JSONDecoder().decode(DebugDeviceSeed.self, from: data)
            else { return }

            let now = ISO8601DateFormatter().string(from: Date())
            let records: [SpacesMobilePairedDeviceRecord] = seed.devices.compactMap { seededDevice in
                let host = seededDevice.host.trimmingCharacters(in: .whitespacesAndNewlines)
                let fingerprint = seededDevice.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
                let authToken = seededDevice.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, (1...65_535).contains(seededDevice.port), !fingerprint.isEmpty, !authToken.isEmpty
                else { return nil }

                let id = seededDevice.id?.nilIfBlank ?? deviceID(
                    certificateFingerprint: fingerprint,
                    host: host,
                    port: seededDevice.port
                )
                saveSecret(authToken, deviceID: id, kind: .authToken)
                return SpacesMobilePairedDeviceRecord(
                    id: id,
                    name: seededDevice.name.nilIfBlank ?? host,
                    host: host,
                    port: seededDevice.port,
                    certificateFingerprint: fingerprint,
                    createdAt: seededDevice.createdAt ?? now,
                    updatedAt: seededDevice.updatedAt ?? now,
                    lastSelectedAt: seededDevice.lastSelectedAt ?? now
                )
            }
            guard !records.isEmpty else { return }

            saveDevices(records)
            let activeID = seed.activeDeviceID?.nilIfBlank.flatMap { requestedID in
                records.contains(where: { $0.id == requestedID }) ? requestedID : nil
            } ?? records.first?.id
            if let activeID {
                UserDefaults.standard.set(activeID, forKey: activeDeviceKey)
            }
        }

        private struct DebugDeviceSeed: Decodable {
            var activeDeviceID: String?
            var devices: [DebugDeviceSeedRecord]
        }

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
            let record = record(from: fallbackSettings, name: fallbackSettings.trimmedHost)
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

    @discardableResult static func upsert(
        settings: SpacesMobileConnectionSettings,
        name: String
    ) -> SpacesMobileDeviceStoreState {
        let now = ISO8601DateFormatter().string(from: Date())
        var devices = loadDevices()
        var record = record(from: settings, name: name)
        if let existing = devices.first(where: { $0.id == record.id }) {
            record.createdAt = existing.createdAt
        } else {
            record.createdAt = now
        }
        record.updatedAt = now
        record.lastSelectedAt = now
        devices.removeAll { $0.id == record.id }
        devices.insert(record, at: 0)
        saveSecret(settings.authToken, deviceID: record.id, kind: .authToken)
        saveDevices(devices)
        UserDefaults.standard.set(record.id, forKey: activeDeviceKey)
        return load(fallbackSettings: settings)
    }

    @discardableResult static func rename(
        deviceID: String,
        name: String,
        fallbackSettings: SpacesMobileConnectionSettings
    ) -> SpacesMobileDeviceStoreState {
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
    static func authToken(deviceID: String) -> String? {
        secret(deviceID: deviceID, kind: .authToken)
    }

    private static func loadDevices() -> [SpacesMobilePairedDeviceRecord] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let decoded = try? JSONDecoder().decode([SpacesMobilePairedDeviceRecord].self, from: data)
        else { return [] }
        return decoded.sorted {
            ($0.lastSelectedAt ?? $0.updatedAt) > ($1.lastSelectedAt ?? $1.updatedAt)
        }
    }

    private static func saveDevices(_ devices: [SpacesMobilePairedDeviceRecord]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: devicesKey)
    }

    private static func record(from settings: SpacesMobileConnectionSettings, name: String) -> SpacesMobilePairedDeviceRecord {
        let now = ISO8601DateFormatter().string(from: Date())
        return SpacesMobilePairedDeviceRecord(
            id: deviceID(certificateFingerprint: settings.certificateFingerprint, host: settings.trimmedHost, port: settings.port),
            name: name,
            host: settings.trimmedHost,
            port: settings.port,
            certificateFingerprint: settings.certificateFingerprint,
            createdAt: now,
            updatedAt: now,
            lastSelectedAt: now
        )
    }

    private static func settings(from device: SpacesMobilePairedDeviceRecord, installationID: String) -> SpacesMobileConnectionSettings {
        var settings = SpacesMobileConnectionSettings()
        settings.host = device.host
        settings.port = device.port
        settings.certificateFingerprint = device.certificateFingerprint
        settings.authToken = secret(deviceID: device.id, kind: .authToken) ?? ""
        settings.installationID = installationID
        return settings
    }

    private static func deviceID(certificateFingerprint: String, host: String, port: Int) -> String {
        let source = "\(certificateFingerprint)|\(host)|\(port)".lowercased()
        let slug = source.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "device-\(slug.prefix(48))"
    }

    private enum SecretKind: String {
        case authToken
    }

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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func deleteSecret(deviceID: String, kind: SecretKind) {
        SecItemDelete(keychainQuery(deviceID: deviceID, kind: kind) as CFDictionary)
    }

    private static func keychainQuery(deviceID: String, kind: SecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "\(deviceID).\(kind.rawValue)",
        ]
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
