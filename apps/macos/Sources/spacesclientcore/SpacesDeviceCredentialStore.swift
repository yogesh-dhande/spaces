import Foundation
import spacesterminalcore

#if canImport(Security)
    @preconcurrency import Security
    private let spacesErrSecInteractionNotAllowed = errSecInteractionNotAllowed
#else
    public typealias OSStatus = Int32
    private let spacesErrSecInteractionNotAllowed: OSStatus = -25308
#endif

#if canImport(LocalAuthentication)
    import LocalAuthentication
#endif

public enum SpacesDeviceCredentialStoreError: LocalizedError, Equatable {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case invalidStoredToken

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            if status == spacesErrSecInteractionNotAllowed {
                "Keychain access to the paired-device credentials requires approval. Remove and reconnect this device from Spaces."
            } else {
                "Failed to read the paired-device token from Keychain. Security status: \(status)."
            }
        case .keychainWriteFailed(let status): "Failed to save the paired-device token in Keychain. Security status: \(status)."
        case .keychainDeleteFailed(let status): "Failed to delete the paired-device token from Keychain. Security status: \(status)."
        case .invalidStoredToken: "The stored paired-device token is not valid UTF-8."
        }
    }
}

public enum SpacesDeviceCredentialStore {
    public static let secretDirectoryEnvironmentVariable = "SPACES_CLIENT_SECRET_DIR"

    private enum SecretKind {
        case authToken
        case transportKey

        var service: String {
            switch self {
            case .authToken: "dev.usespaces.Spaces.device-auth-token"
            case .transportKey: "dev.usespaces.Spaces.device-transport-key"
            }
        }

        var filePrefix: String {
            switch self {
            case .authToken: "device-auth-token"
            case .transportKey: "device-transport-key"
            }
        }
    }

    public static func token(deviceID: String, profile: SpacesProfile? = nil) throws -> String? {
        try secret(kind: .authToken, deviceID: deviceID, profile: profile)
    }

    public static func transportKey(deviceID: String, profile: SpacesProfile? = nil) throws -> String? {
        try secret(kind: .transportKey, deviceID: deviceID, profile: profile)
    }

    public static func hasToken(deviceID: String, profile: SpacesProfile? = nil) throws -> Bool {
        try hasSecret(kind: .authToken, deviceID: deviceID, profile: profile)
    }

    public static func hasTransportKey(deviceID: String, profile: SpacesProfile? = nil) throws -> Bool {
        try hasSecret(kind: .transportKey, deviceID: deviceID, profile: profile)
    }

    public static func saveToken(_ token: String, deviceID: String, profile: SpacesProfile? = nil) throws {
        try saveSecret(token, kind: .authToken, deviceID: deviceID, profile: profile)
    }

    public static func saveTransportKey(_ transportKey: String, deviceID: String, profile: SpacesProfile? = nil) throws {
        try saveSecret(transportKey, kind: .transportKey, deviceID: deviceID, profile: profile)
    }

    public static func deleteToken(deviceID: String, profile: SpacesProfile? = nil) throws {
        try deleteSecret(kind: .authToken, deviceID: deviceID, profile: profile)
    }

    public static func deleteTransportKey(deviceID: String, profile: SpacesProfile? = nil) throws {
        try deleteSecret(kind: .transportKey, deviceID: deviceID, profile: profile)
    }

    private static func secret(kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws -> String? {
        if let fileURL = secretFileURL(kind: kind, deviceID: deviceID) { return try fileSecret(at: fileURL) }
        #if canImport(Security)
            let query = try baseQuery(kind: kind, deviceID: deviceID, profile: profile).merging(
                [kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne], uniquingKeysWith: { _, new in new }
            ).merging(nonInteractiveKeychainQueryAttributes(), uniquingKeysWith: { _, new in new })
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw SpacesDeviceCredentialStoreError.keychainReadFailed(status) }
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw SpacesDeviceCredentialStoreError.invalidStoredToken
            }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        #else
            return nil
        #endif
    }

    private static func hasSecret(kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws -> Bool {
        if let fileURL = secretFileURL(kind: kind, deviceID: deviceID) { return try fileSecret(at: fileURL) != nil }
        #if canImport(Security)
            let query = try baseQuery(kind: kind, deviceID: deviceID, profile: profile).merging(
                [kSecReturnData as String: false, kSecMatchLimit as String: kSecMatchLimitOne], uniquingKeysWith: { _, new in new }
            ).merging(nonInteractiveKeychainQueryAttributes(), uniquingKeysWith: { _, new in new })
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecItemNotFound { return false }
            guard status == errSecSuccess else { throw SpacesDeviceCredentialStoreError.keychainReadFailed(status) }
            return true
        #else
            return false
        #endif
    }

    private static func saveSecret(_ value: String, kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws {
        if let fileURL = secretFileURL(kind: kind, deviceID: deviceID) {
            try saveFileSecret(value, at: fileURL)
            return
        }
        #if canImport(Security)
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try deleteSecret(kind: kind, deviceID: deviceID, profile: profile)
                return
            }
            let tokenData = Data(trimmed.utf8)
            let query = try baseQuery(kind: kind, deviceID: deviceID, profile: profile)
            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw SpacesDeviceCredentialStoreError.keychainDeleteFailed(deleteStatus)
            }
            var addQuery = query
            addQuery[kSecValueData as String] = tokenData
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SpacesDeviceCredentialStoreError.keychainWriteFailed(addStatus) }
        #endif
    }

    private static func deleteSecret(kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws {
        if let fileURL = secretFileURL(kind: kind, deviceID: deviceID) {
            try deleteFileSecret(at: fileURL)
            return
        }
        #if canImport(Security)
            let status = SecItemDelete(try baseQuery(kind: kind, deviceID: deviceID, profile: profile) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SpacesDeviceCredentialStoreError.keychainDeleteFailed(status) }
        #endif
    }

    private static func secretFileURL(kind: SecretKind, deviceID: String) -> URL? {
        guard let directory = fileSecretDirectoryURL() else { return nil }
        return directory.appendingPathComponent("\(kind.filePrefix)-\(sanitizeFileComponent(deviceID)).secret", isDirectory: false)
    }

    private static func fileSecretDirectoryURL() -> URL? {
        guard let rawValue = ProcessInfo.processInfo.environment[secretDirectoryEnvironmentVariable] else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    private static func fileSecret(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8) else { throw SpacesDeviceCredentialStoreError.invalidStoredToken }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func saveFileSecret(_ value: String, at url: URL) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteFileSecret(at: url)
            return
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        try Data(trimmed.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    private static func deleteFileSecret(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func sanitizeFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0).description : "_" }
        let sanitized = scalars.joined().trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized.isEmpty ? SpacesProfile.shortStableHash(value) : sanitized
    }

    #if canImport(Security)
        private static func baseQuery(kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws -> [String: Any] {
            let resolvedProfile = try profile ?? SpacesProfile.current()
            return [
                kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: kind.service,
                kSecAttrAccount as String: "\(resolvedProfile.rootDirectory)#\(deviceID)",
            ]
        }

        private static func nonInteractiveKeychainQueryAttributes() -> [String: Any] {
            #if canImport(LocalAuthentication)
                let context = LAContext()
                context.interactionNotAllowed = true
                return [kSecUseAuthenticationContext as String: context]
            #else
                return [kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
            #endif
        }
    #endif
}
