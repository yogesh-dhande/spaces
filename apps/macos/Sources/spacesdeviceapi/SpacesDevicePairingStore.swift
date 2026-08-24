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

    /// True when two records describe the same pairing in the same terms and differ at most in when it
    /// was last seen — the condition under which persisting is pure timestamp churn.
    func differsOnlyInLastUsedAt(from other: SpacesDevicePairedInstallation) -> Bool {
        installationID == other.installationID && bundleID == other.bundleID && platform == other.platform && deviceName == other.deviceName
            && appVersion == other.appVersion && tokenHash == other.tokenHash && createdAt == other.createdAt
    }
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
    /// Serializes every read-modify-write of the pairings file, across every store instance that names the
    /// same file rather than per instance. Two things make that necessary. The store is reached from more
    /// than one queue by design: the Device API answers `.ping` on the receiving connection's own queue,
    /// clear of the shared request queue, and that answer still authorizes first (see
    /// `SpacesDeviceAPIServer.RequestConnection`). And more than one store exists at a time:
    /// `SpacesDeviceAPISupervisor` builds a fresh one per control request (bootstrap, revoke, reset) while
    /// the running server holds its own. Two instances under two locks lose updates against each other —
    /// a revoke writes the filtered array, then an authorization that loaded the file before it writes its
    /// own array back and the revoked token is paired again. Every mutation loads the file *inside* this
    /// lock, so the load, the edit, and the write are one critical section; nothing here may read the file
    /// before taking it. `@unchecked Sendable` is only honest with this lock.
    private let lock: NSLock

    /// Guards the lock registry itself. One process-wide `NSLock` per pairings file, created on first use
    /// and kept: the set of paths a process touches is its profile's, so this never grows meaningfully.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var locksByPairingsPath: [String: NSLock] = [:]

    private static func lock(forPairingsPath path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locksByPairingsPath[path] { return existing }
        let created = NSLock()
        locksByPairingsPath[path] = created
        return created
    }
    /// `ISO8601DateFormatter` construction is the expensive half of ISO8601 formatting (an ICU
    /// `udat_open` per instance) and `issueToken` runs on the daemon's main actor for every
    /// `bootstrapLocalClient`, which the app dials on every endpoint recovery and the local client
    /// re-dials on every sidebar reload. The formatter is thread-safe, so one instance serves the process,
    /// matching `GhosttyRemoteSessionState`'s cached formatters.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    /// How stale a persisted `lastUsedAt` may get before a write is spent refreshing it.
    ///
    /// Every authorized request and every bootstrap used to rewrite the whole pairings file (encode,
    /// temp file, rename) purely to move this one field, on paths that are otherwise pure reads — the
    /// authorize hop sits in front of every keystroke's control request. `lastUsedAt` exists to tell the
    /// user when a paired device was last seen, a display for which hour granularity is indistinguishable
    /// from exact, so the steady state writes nothing and a device that keeps talking refreshes at most
    /// once an hour. Anything else about a pairing (a renamed device, a new app version, a fresh token)
    /// still persists immediately.
    private static let lastUsedAtRefreshInterval: TimeInterval = 60 * 60

    public init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let root = try TerminalServicePaths.terminalRootDirectory(fileManager: fileManager)
        // Standardized so two instances that spell the same file differently still resolve to one lock.
        pairingsPath = root.appendingPathComponent("device-pairings.json", isDirectory: false).standardizedFileURL.path
        lock = Self.lock(forPairingsPath: pairingsPath)
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
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
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
            appVersion: clientApp.appVersion, tokenHash: Self.hash(token), createdAt: existing?.createdAt ?? Self.timestamp(now),
            lastUsedAt: Self.timestamp(now))
        try replace(existing: existing, with: paired, in: &pairings, at: now)
        return token
    }

    public func listDevices() throws -> [SpacesDevicePairedClient] {
        lock.lock()
        defer { lock.unlock() }
        return try loadPairings().map { pairing in
            SpacesDevicePairedClient(
                installationID: pairing.installationID, bundleID: pairing.bundleID, platform: pairing.platform, deviceName: pairing.deviceName,
                appVersion: pairing.appVersion, createdAt: pairing.createdAt, lastUsedAt: pairing.lastUsedAt)
        }
    }

    public func revoke(installationID: String) throws {
        let normalizedID = installationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let pairings = try loadPairings().filter { $0.installationID != normalizedID }
        try savePairings(pairings)
    }

    public func removeAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try savePairings([])
    }

    public func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard let clientApp else { throw SpacesDevicePairingError.missingClientApp }
        try validate(clientApp: clientApp)
        guard let authToken, !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpacesDevicePairingError.missingAuthToken
        }

        lock.lock()
        defer { lock.unlock() }
        var pairings = try loadPairings()
        guard let index = pairings.firstIndex(where: { $0.installationID == clientApp.installationID }) else {
            throw SpacesDevicePairingError.unpairedInstallation(clientApp.installationID)
        }

        let paired = pairings[index]
        guard paired.bundleID == clientApp.bundleID, paired.tokenHash == Self.hash(authToken) else { throw SpacesDevicePairingError.invalidAuthToken }

        let now = Date()
        let refreshed = SpacesDevicePairedInstallation(
            installationID: paired.installationID, bundleID: paired.bundleID, platform: clientApp.platform, deviceName: clientApp.deviceName,
            appVersion: clientApp.appVersion, tokenHash: paired.tokenHash, createdAt: paired.createdAt, lastUsedAt: Self.timestamp(now))
        try replace(existing: paired, with: refreshed, in: &pairings, at: now)
    }

    /// Applies `updated` to `pairings` and persists, unless the only difference from `existing` is a
    /// `lastUsedAt` that was already refreshed within `lastUsedAtRefreshInterval` — see that constant for
    /// why a stale-by-an-hour timestamp is the right trade against a whole-file rewrite per request.
    /// An unparseable stored timestamp counts as stale, so one write repairs it.
    private func replace(
        existing: SpacesDevicePairedInstallation?, with updated: SpacesDevicePairedInstallation, in pairings: inout [SpacesDevicePairedInstallation],
        at now: Date
    ) throws {
        if let existing, existing.differsOnlyInLastUsedAt(from: updated), let lastUsedAt = Self.timestampFormatter.date(from: existing.lastUsedAt),
            now.timeIntervalSince(lastUsedAt) < Self.lastUsedAtRefreshInterval
        {
            return
        }
        if let index = pairings.firstIndex(where: { $0.installationID == updated.installationID }) {
            pairings[index] = updated
        } else {
            pairings.append(updated)
        }
        try savePairings(pairings)
    }

    private static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }

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
