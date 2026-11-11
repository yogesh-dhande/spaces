import Foundation

/// A daemon's report of its own ability to update itself. The field is present on a status only when
/// the daemon can do it (an installed Linux release daemon); its absence means "update this device
/// another way", never "no update".
///
/// Availability is a fact the daemon reports about its own channel feed. A client never derives it by
/// comparing the daemon's version against anything it knows itself (see `AGENTS.md` Version Metadata
/// Rules).
public struct DaemonSelfUpdateStatus: Codable, Sendable, Equatable {
    public let channel: DaemonUpdateChannel
    /// The newest version on `channel`, present only when it is newer than the running version. Nil
    /// before the first successful check.
    public let availableVersion: String?
    public let progress: DaemonSelfUpdateProgress?

    public init(channel: DaemonUpdateChannel, availableVersion: String? = nil, progress: DaemonSelfUpdateProgress? = nil) {
        self.channel = channel
        self.availableVersion = availableVersion
        self.progress = progress
    }
}
