import Foundation
import spacesmobilecore

public struct SpacesMobilePairingWindow: Codable, Equatable, Sendable {
    public let nonce: String
    public let code: String
    public let expiresAt: Date
    public let link: SpacesMobilePairingLink

    public var linkString: String { link.absoluteString }
}

public struct SpacesMobilePairingWindowSnapshot: Codable, Equatable, Sendable {
    public let nonce: String
    public let code: String
    public let expiresAt: Date
    public let linkString: String

    public init(window: SpacesMobilePairingWindow) {
        nonce = window.nonce
        code = window.code
        expiresAt = window.expiresAt
        linkString = window.linkString
    }
}

public enum SpacesMobilePairingCoordinatorError: LocalizedError, Equatable {
    case failed

    public var errorDescription: String? { "Pairing failed. Open a new pairing window on your Mac and try again." }
}

public final class SpacesMobilePairingCoordinator: @unchecked Sendable {
    public static let defaultWindowDuration: TimeInterval = 5 * 60
    public static let maxFailedAttempts = 5

    private struct ActiveWindow {
        let window: SpacesMobilePairingWindow
        var failedAttempts: Int
        var isConsumed: Bool
    }

    private let lock = NSLock()
    private var activeWindow: ActiveWindow?
    private var failedAttemptsByPeer: [String: (count: Int, lastAttemptAt: Date)] = [:]

    public init() {}

    public func openWindow(
        host: String, port: Int, transportKey: String, name: String, now: Date = Date(), duration: TimeInterval = defaultWindowDuration,
        code overrideCode: String? = nil, nonce overrideNonce: String? = nil
    ) -> SpacesMobilePairingWindow {
        let code = overrideCode ?? Self.generatePairingCode()
        let nonce = overrideNonce ?? UUID().uuidString.uppercased()
        let link = SpacesMobilePairingLink(host: host, port: port, nonce: nonce, code: code, transportKey: transportKey, name: name)
        let window = SpacesMobilePairingWindow(nonce: nonce, code: code, expiresAt: now.addingTimeInterval(duration), link: link)
        lock.lock()
        activeWindow = ActiveWindow(window: window, failedAttempts: 0, isConsumed: false)
        prunePeerFailures(now: now)
        lock.unlock()
        return window
    }

    public func snapshot(now: Date = Date()) -> SpacesMobilePairingWindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let activeWindow, !activeWindow.isConsumed, activeWindow.window.expiresAt > now else { return nil }
        return SpacesMobilePairingWindowSnapshot(window: activeWindow.window)
    }

    public func validate(code: String?, nonce: String?, peerID: String, now: Date = Date()) throws {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedNonce = nonce?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        defer { lock.unlock() }
        prunePeerFailures(now: now)
        guard failedAttemptsByPeer[peerID]?.count ?? 0 < Self.maxFailedAttempts else { throw SpacesMobilePairingCoordinatorError.failed }
        guard var activeWindow, !activeWindow.isConsumed, activeWindow.window.expiresAt > now else {
            recordFailure(peerID: peerID, now: now)
            throw SpacesMobilePairingCoordinatorError.failed
        }
        guard activeWindow.failedAttempts < Self.maxFailedAttempts else {
            recordFailure(peerID: peerID, now: now)
            throw SpacesMobilePairingCoordinatorError.failed
        }
        guard normalizedCode == activeWindow.window.code, normalizedNonce == activeWindow.window.nonce else {
            activeWindow.failedAttempts += 1
            self.activeWindow = activeWindow
            recordFailure(peerID: peerID, now: now)
            throw SpacesMobilePairingCoordinatorError.failed
        }
        activeWindow.isConsumed = true
        self.activeWindow = activeWindow
        failedAttemptsByPeer.removeValue(forKey: peerID)
    }

    public static func generatePairingCode() -> String { String(format: "%08d", Int.random(in: 0...99_999_999)) }

    private func recordFailure(peerID: String, now: Date) {
        let current = failedAttemptsByPeer[peerID]?.count ?? 0
        failedAttemptsByPeer[peerID] = (current + 1, now)
    }

    private func prunePeerFailures(now: Date) {
        failedAttemptsByPeer = failedAttemptsByPeer.filter { now.timeIntervalSince($0.value.lastAttemptAt) < Self.defaultWindowDuration }
    }
}
