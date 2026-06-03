import CryptoKit
import Foundation
import spacesmobilecore
import spacesterminalcore

public struct SpacesMobilePairedInstallation: Codable, Equatable {
    let installationID: String
    let bundleID: String
    let platform: String
    let deviceName: String
    let appVersion: String?
    let tokenHash: String
    let createdAt: String
    let lastUsedAt: String
}

public struct SpacesMobilePairedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { installationID }
    public let installationID: String
    public let bundleID: String
    public let platform: String
    public let deviceName: String
    public let appVersion: String?
    public let createdAt: String
    public let lastUsedAt: String
}

public enum SpacesMobilePairingError: LocalizedError {
    case unsupportedBundle(String)
    case missingClientApp
    case missingAuthToken
    case invalidAuthToken
    case unpairedInstallation(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBundle(let bundleID): "Unsupported mobile bundle '\(bundleID)'."
        case .missingClientApp: "Missing mobile client application identity."
        case .missingAuthToken: "Missing mobile auth token."
        case .invalidAuthToken: "The mobile auth token is invalid."
        case .unpairedInstallation(let installationID): "The mobile installation '\(installationID)' is not paired."
        }
    }
}

public final class SpacesMobilePairingStore: @unchecked Sendable {
    private let pairingsPath: String
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        pairingsPath = root.appendingPathComponent("mobile-pairings.json", isDirectory: false).path
    }

    public func issueToken(for clientApp: SpacesMobileClientApp) throws -> String {
        try validate(clientApp: clientApp)

        let now = ISO8601DateFormatter().string(from: Date())
        let token = UUID().uuidString.uppercased()
        var pairings = try loadPairings()
        let paired = SpacesMobilePairedInstallation(
            installationID: clientApp.installationID, bundleID: clientApp.bundleID, platform: clientApp.platform, deviceName: clientApp.deviceName,
            appVersion: clientApp.appVersion, tokenHash: Self.hash(token),
            createdAt: pairings.first(where: { $0.installationID == clientApp.installationID })?.createdAt ?? now, lastUsedAt: now)
        if let index = pairings.firstIndex(where: { $0.installationID == clientApp.installationID }) {
            pairings[index] = paired
        } else {
            pairings.append(paired)
        }
        try savePairings(pairings)
        return token
    }

    public func listDevices() throws -> [SpacesMobilePairedDevice] {
        try loadPairings().map { pairing in
            SpacesMobilePairedDevice(
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

    public func authorize(clientApp: SpacesMobileClientApp?, authToken: String?) throws {
        guard let clientApp else { throw SpacesMobilePairingError.missingClientApp }
        try validate(clientApp: clientApp)
        guard let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpacesMobilePairingError.missingAuthToken
        }

        var pairings = try loadPairings()
        guard let index = pairings.firstIndex(where: { $0.installationID == clientApp.installationID }) else {
            throw SpacesMobilePairingError.unpairedInstallation(clientApp.installationID)
        }

        let paired = pairings[index]
        guard paired.bundleID == clientApp.bundleID, paired.tokenHash == Self.hash(authToken) else { throw SpacesMobilePairingError.invalidAuthToken }

        pairings[index] = SpacesMobilePairedInstallation(
            installationID: paired.installationID, bundleID: paired.bundleID, platform: clientApp.platform, deviceName: clientApp.deviceName,
            appVersion: clientApp.appVersion, tokenHash: paired.tokenHash, createdAt: paired.createdAt,
            lastUsedAt: ISO8601DateFormatter().string(from: Date()))
        try savePairings(pairings)
    }

    public func validate(clientApp: SpacesMobileClientApp) throws {
        guard clientApp.bundleID == SpacesMobileFirstPartyPolicy.allowedBundleID else {
            throw SpacesMobilePairingError.unsupportedBundle(clientApp.bundleID)
        }
    }

    private func loadPairings() throws -> [SpacesMobilePairedInstallation] {
        guard fileManager.fileExists(atPath: pairingsPath) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: pairingsPath))
        return try JSONDecoder().decode([SpacesMobilePairedInstallation].self, from: data)
    }

    private func savePairings(_ pairings: [SpacesMobilePairedInstallation]) throws {
        let root = URL(fileURLWithPath: pairingsPath).deletingLastPathComponent()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pairings.sorted { $0.createdAt < $1.createdAt })
        try data.write(to: URL(fileURLWithPath: pairingsPath), options: [.atomic])
    }

    private static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
