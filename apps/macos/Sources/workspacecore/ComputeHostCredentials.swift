import Foundation
@preconcurrency import Security
import spacesterminalcore

public enum ComputeHostCredentialStoreError: LocalizedError, Equatable {
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainDeleteFailed(OSStatus)
    case invalidStoredToken

    public var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status): "Failed to read the compute host token from Keychain. Security status: \(status)."
        case .keychainWriteFailed(let status): "Failed to save the compute host token in Keychain. Security status: \(status)."
        case .keychainDeleteFailed(let status): "Failed to delete the compute host token from Keychain. Security status: \(status)."
        case .invalidStoredToken: "The stored compute host token is not valid UTF-8."
        }
    }
}

public enum ComputeHostCredentialStore {
    private static let service = "app.asmvik.Spaces.spacesd-auth-token"

    public static func generateAuthToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = status == errSecSuccess ? Data(bytes) : Data((UUID().uuidString + UUID().uuidString).utf8)
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(
            of: "=", with: "")
    }

    public static func authToken(hostID: String, profile: SpacesProfile? = nil) throws -> String? {
        let query = try baseQuery(hostID: hostID, profile: profile).merging([
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ComputeHostCredentialStoreError.keychainReadFailed(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ComputeHostCredentialStoreError.invalidStoredToken
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func saveAuthToken(_ token: String, hostID: String, profile: SpacesProfile? = nil) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAuthToken(hostID: hostID, profile: profile)
            return
        }
        let tokenData = Data(trimmed.utf8)
        let query = try baseQuery(hostID: hostID, profile: profile)
        let update: [String: Any] = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw ComputeHostCredentialStoreError.keychainWriteFailed(updateStatus) }
        var addQuery = query
        addQuery[kSecValueData as String] = tokenData
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw ComputeHostCredentialStoreError.keychainWriteFailed(addStatus) }
    }

    public static func deleteAuthToken(hostID: String, profile: SpacesProfile? = nil) throws {
        let status = SecItemDelete(try baseQuery(hostID: hostID, profile: profile) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ComputeHostCredentialStoreError.keychainDeleteFailed(status) }
    }

    private static func baseQuery(hostID: String, profile: SpacesProfile?) throws -> [String: Any] {
        let resolvedProfile = try profile ?? SpacesProfile.current()
        return [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "\(resolvedProfile.rootDirectory)#\(hostID)",
        ]
    }
}
