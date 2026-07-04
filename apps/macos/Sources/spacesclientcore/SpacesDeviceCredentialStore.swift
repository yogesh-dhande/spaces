import Foundation
import spacesterminalcore

public enum SpacesDeviceCredentialStoreError: LocalizedError, Equatable {
    case invalidStoredToken

    public var errorDescription: String? {
        switch self {
        case .invalidStoredToken: "The stored paired-device token is not valid UTF-8. Remove and reconnect this device from Spaces."
        }
    }
}

/// Owner-only file storage for paired-device secrets. Secrets live in a 0700 directory of 0600
/// files so every client process on this machine that shares the profile — the GUI app, the
/// `spaces` CLI, and the MCP server — can read them headlessly. Keychain is deliberately not used:
/// its per-binary ACLs cannot be shared with CLI/agent processes without interactive prompts.
public enum SpacesDeviceCredentialStore {
    public static let secretDirectoryEnvironmentVariable = "SPACES_CLIENT_SECRET_DIR"
    static let secretDirectoryName = "client-secrets"

    private enum SecretKind {
        case authToken
        case transportKey

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
        try secret(kind: .authToken, deviceID: deviceID, profile: profile) != nil
    }

    public static func hasTransportKey(deviceID: String, profile: SpacesProfile? = nil) throws -> Bool {
        try secret(kind: .transportKey, deviceID: deviceID, profile: profile) != nil
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
        try fileSecret(at: secretFileURL(kind: kind, deviceID: deviceID, profile: profile))
    }

    private static func saveSecret(_ value: String, kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws {
        try saveFileSecret(value, at: secretFileURL(kind: kind, deviceID: deviceID, profile: profile))
    }

    private static func deleteSecret(kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws {
        try deleteFileSecret(at: secretFileURL(kind: kind, deviceID: deviceID, profile: profile))
    }

    private static func secretFileURL(kind: SecretKind, deviceID: String, profile: SpacesProfile?) throws -> URL {
        try secretDirectoryURL(profile: profile)
            .appendingPathComponent("\(kind.filePrefix)-\(sanitizeFileComponent(deviceID)).secret", isDirectory: false)
    }

    private static func secretDirectoryURL(profile: SpacesProfile?) throws -> URL {
        if let rawValue = ProcessInfo.processInfo.environment[secretDirectoryEnvironmentVariable] {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            }
        }
        let resolvedProfile = try profile ?? SpacesProfile.current()
        return URL(fileURLWithPath: resolvedProfile.rootDirectory, isDirectory: true)
            .appendingPathComponent(secretDirectoryName, isDirectory: true)
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
}
