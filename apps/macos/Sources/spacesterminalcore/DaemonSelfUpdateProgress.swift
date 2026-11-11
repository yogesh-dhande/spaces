import Foundation

/// What a daemon's own update run is doing right now, reported by the daemon so every client shows the
/// same thing.
public struct DaemonSelfUpdateProgress: Codable, Sendable, Equatable {
    public enum Step: String, Codable, Sendable, Equatable {
        case downloading
        case installing
        case restarting
        case failed
    }

    public let targetVersion: String
    public let step: Step
    /// Bytes of the archive on disk so far. Present only while `downloading`.
    public let receivedBytes: Int64?
    /// Size of the archive. Present only while `downloading`, and nil when the release manifest does
    /// not carry a size (older releases), in which case a client shows the received bytes alone.
    public let totalBytes: Int64?
    /// A sentence fit to show the user. Present only when `failed`.
    public let failureReason: String?

    public init(targetVersion: String, step: Step, receivedBytes: Int64? = nil, totalBytes: Int64? = nil, failureReason: String? = nil) {
        self.targetVersion = targetVersion
        self.step = step
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.failureReason = failureReason
    }
}
