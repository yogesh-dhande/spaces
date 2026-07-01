import Foundation
import spacesdevicecore
import spacesterminalcore

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(OpenSSL)
    import OpenSSL
#endif

public struct SpacesDevicePairedInstallation: Codable, Equatable {
    let installationID: String
    let bundleID: String
    let platform: String
    let deviceName: String
    let appVersion: String?
    let tokenHash: String
    let createdAt: String
    let lastUsedAt: String
}

public struct SpacesDevicePairedClient: Codable, Equatable, Sendable, Identifiable {
    public var id: String { installationID }
    public let installationID: String
    public let bundleID: String
    public let platform: String
    public let deviceName: String
    public let appVersion: String?
    public let createdAt: String
    public let lastUsedAt: String
}

public enum SpacesDevicePairingError: LocalizedError {
    case unsupportedBundle(String)
    case missingClientApp
    case missingAuthToken
    case invalidAuthToken
    case unpairedInstallation(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBundle(let bundleID): "Unsupported Spaces client bundle '\(bundleID)'."
        case .missingClientApp: "Missing device client application identity."
        case .missingAuthToken: "Missing device auth token."
        case .invalidAuthToken: "The device auth token is invalid."
        case .unpairedInstallation(let installationID): "The client installation '\(installationID)' is not paired."
        }
    }
}

public final class SpacesDevicePairingStore: @unchecked Sendable {
    private let pairingsPath: String
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        pairingsPath = root.appendingPathComponent("device-pairings.json", isDirectory: false).path
    }

    /// Issues (or refreshes) the auth token for a client installation and persists its hash.
    ///
    /// When `presentedToken` still matches the stored pairing for this installation, it is kept
    /// and returned unchanged. This keeps an already-paired client's token stable across repeated
    /// bootstraps — the local first-party client re-bootstraps on every sidebar reload, and minting
    /// a new token each time silently invalidated the token held by every live Device API connection
    /// (terminal state streams and control requests), which surfaced as terminal input being dropped
    /// and "terminal session is no longer available" errors. A missing or stale presented token mints
    /// a fresh token, which is the first-pair and re-pair path.
    public func issueToken(for clientApp: SpacesDeviceClientApp, presentedToken: String? = nil) throws -> String {
        try validate(clientApp: clientApp)

        let now = ISO8601DateFormatter().string(from: Date())
        var pairings = try loadPairings()
        let existing = pairings.first(where: { $0.installationID == clientApp.installationID })

        let token: String
        if let existing, existing.bundleID == clientApp.bundleID,
            let presentedToken = presentedToken?.trimmingCharacters(in: .whitespacesAndNewlines), !presentedToken.isEmpty,
            existing.tokenHash == Self.hash(presentedToken)
        {
            token = presentedToken
        } else {
            token = UUID().uuidString.uppercased()
        }

        let paired = SpacesDevicePairedInstallation(
            installationID: clientApp.installationID, bundleID: clientApp.bundleID, platform: clientApp.platform, deviceName: clientApp.deviceName,
            appVersion: clientApp.appVersion, tokenHash: Self.hash(token), createdAt: existing?.createdAt ?? now, lastUsedAt: now)
        if let index = pairings.firstIndex(where: { $0.installationID == clientApp.installationID }) {
            pairings[index] = paired
        } else {
            pairings.append(paired)
        }
        try savePairings(pairings)
        return token
    }

    public func listDevices() throws -> [SpacesDevicePairedClient] {
        try loadPairings().map { pairing in
            SpacesDevicePairedClient(
                installationID: pairing.installationID, bundleID: pairing.bundleID, platform: pairing.platform, deviceName: pairing.deviceName,
                appVersion: pairing.appVersion, createdAt: pairing.createdAt, lastUsedAt: pairing.lastUsedAt)
        }
    }

    public func revoke(installationID: String) throws {
        let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        let pairings = try loadPairings().filter { $0.installationID != normalizedID }
        try savePairings(pairings)
    }

    public func removeAll() throws { try savePairings([]) }

    public func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard let clientApp else { throw SpacesDevicePairingError.missingClientApp }
        try validate(clientApp: clientApp)
        guard let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpacesDevicePairingError.missingAuthToken
        }

        var pairings = try loadPairings()
        guard let index = pairings.firstIndex(where: { $0.installationID == clientApp.installationID }) else {
            throw SpacesDevicePairingError.unpairedInstallation(clientApp.installationID)
        }

        let paired = pairings[index]
        guard paired.bundleID == clientApp.bundleID, paired.tokenHash == Self.hash(authToken) else { throw SpacesDevicePairingError.invalidAuthToken }

        pairings[index] = SpacesDevicePairedInstallation(
            installationID: paired.installationID, bundleID: paired.bundleID, platform: clientApp.platform, deviceName: clientApp.deviceName,
            appVersion: clientApp.appVersion, tokenHash: paired.tokenHash, createdAt: paired.createdAt,
            lastUsedAt: ISO8601DateFormatter().string(from: Date()))
        try savePairings(pairings)
    }

    public func validate(clientApp: SpacesDeviceClientApp) throws {
        guard SpacesDeviceFirstPartyPolicy.allows(bundleID: clientApp.bundleID) else {
            throw SpacesDevicePairingError.unsupportedBundle(clientApp.bundleID)
        }
    }

    private func loadPairings() throws -> [SpacesDevicePairedInstallation] {
        guard fileManager.fileExists(atPath: pairingsPath) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: pairingsPath))
        return try JSONDecoder().decode([SpacesDevicePairedInstallation].self, from: data)
    }

    private func savePairings(_ pairings: [SpacesDevicePairedInstallation]) throws {
        let root = URL(fileURLWithPath: pairingsPath).deletingLastPathComponent()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pairings.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: URL(fileURLWithPath: pairingsPath), options: [.atomic])
    }

    private static func hash(_ token: String) -> String {
        #if canImport(CryptoKit)
            let digest = SHA256.hash(data: Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        #elseif canImport(OpenSSL)
            let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
            var digest = [UInt8](repeating: 0, count: Int(SHA256_DIGEST_LENGTH))
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                _ = OpenSSL.SHA256(baseAddress, data.count, &digest)
            }
            return digest.map { String(format: "%02x", $0) }.joined()
        #else
            preconditionFailure("SpacesDevicePairingStore requires SHA-256 support.")
        #endif
    }
}
