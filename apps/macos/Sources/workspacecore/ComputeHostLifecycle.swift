import Foundation

public enum ComputeHostUpgradeState: String, Codable, Sendable, Equatable {
    case current
    case upgradeAvailable
    case unknown
}

public struct ComputeHostDaemonStatusReport: Codable, Sendable, Equatable {
    public let daemonVersion: String?
    public let artifactVersion: String?
    public let certificateFingerprint: String?
    public let activeSessionCount: Int?
    public let savedCertificateFingerprint: String
    public let appVersion: String

    public init(
        daemonVersion: String?, artifactVersion: String?, certificateFingerprint: String?, activeSessionCount: Int?,
        savedCertificateFingerprint: String, appVersion: String = AppVersion.current
    ) {
        self.daemonVersion = Self.normalized(daemonVersion)
        self.artifactVersion = Self.normalized(artifactVersion)
        self.certificateFingerprint = Self.normalized(certificateFingerprint)
        self.activeSessionCount = activeSessionCount
        self.savedCertificateFingerprint = savedCertificateFingerprint
        self.appVersion = appVersion
    }

    public var certificatePinMatches: Bool? {
        guard let certificateFingerprint else { return nil }
        return certificateFingerprint == savedCertificateFingerprint
    }

    public var upgradeState: ComputeHostUpgradeState {
        guard let artifactVersion else { return .unknown }
        return artifactVersion == appVersion ? .current : .upgradeAvailable
    }

    public var displayText: String {
        var parts = ["Reachable"]
        if let daemonVersion { parts.append("daemon \(daemonVersion)") } else { parts.append("daemon unknown") }
        if let artifactVersion { parts.append("artifact \(artifactVersion)") } else { parts.append("artifact unknown") }
        parts.append(certificatePinText)
        if let activeSessionCount { parts.append("\(activeSessionCount) active session\(activeSessionCount == 1 ? "" : "s")") }
        parts.append(upgradeText)
        return parts.joined(separator: " · ")
    }

    private var certificatePinText: String {
        switch certificatePinMatches {
        case .some(true): "pin matched"
        case .some(false): "pin mismatch"
        case .none: "pin unknown"
        }
    }

    private var upgradeText: String {
        switch upgradeState {
        case .current: "current"
        case .upgradeAvailable: "upgrade available"
        case .unknown: "upgrade unknown"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
