import CryptoKit
import Foundation
import spacesmobilecore
import spacesterminalcore

struct SpacesMobilePairedInstallation: Codable, Equatable {
    let installationID: String
    let bundleID: String
    let platform: String
    let deviceName: String
    let appVersion: String?
    let tokenHash: String
    let createdAt: String
    let lastUsedAt: String
}

enum SpacesMobilePairingError: LocalizedError {
    case unsupportedBundle(String)
    case missingClientApp
    case missingAuthToken
    case missingPairingCode
    case invalidPairingCode
    case invalidAuthToken
    case unpairedInstallation(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBundle(let bundleID): "Unsupported mobile bundle '\(bundleID)'."
        case .missingClientApp: "Missing mobile client application identity."
        case .missingAuthToken: "Missing mobile auth token."
        case .missingPairingCode: "Missing mobile pairing code."
        case .invalidPairingCode: "The pairing code is invalid."
        case .invalidAuthToken: "The mobile auth token is invalid."
        case .unpairedInstallation(let installationID): "The mobile installation '\(installationID)' is not paired."
        }
    }
}

final class SpacesMobilePairingStore: @unchecked Sendable {
    private let pairingsPath: String
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        pairingsPath = root.appendingPathComponent("mobile-pairings.json", isDirectory: false).path
    }

    func issueToken(for clientApp: SpacesMobileClientApp, pairingCode: String, expectedPairingCode: String) throws -> String {
        try validate(clientApp: clientApp)
        let normalizedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else { throw SpacesMobilePairingError.missingPairingCode }
        guard normalizedCode == expectedPairingCode else { throw SpacesMobilePairingError.invalidPairingCode }

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

    func authorize(clientApp: SpacesMobileClientApp?, authToken: String?) throws {
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

    private func validate(clientApp: SpacesMobileClientApp) throws {
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
