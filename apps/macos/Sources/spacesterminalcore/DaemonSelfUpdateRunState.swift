import Foundation

/// The record of the update run a daemon last launched, kept beside the runner's log so a restarted
/// daemon (the update itself restarts it) still knows what it was installing.
public struct DaemonSelfUpdateRunState: Codable, Sendable, Equatable {
    public let targetVersion: String

    public init(targetVersion: String) {
        self.targetVersion = targetVersion
    }
}
