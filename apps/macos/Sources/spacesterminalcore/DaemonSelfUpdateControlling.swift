import Foundation

/// How a request to start a self-update ended.
public enum DaemonSelfUpdateStartOutcome: Equatable, Sendable {
    case started
    /// A run is already in flight; asking again is a harmless no-op.
    case alreadyRunning
    /// The daemon's channel has nothing newer than the running version.
    case upToDate
    /// The runner could not be launched; the message is fit to show the user.
    case launchFailed(String)
}

/// The operations the Device API hands to a daemon that can update itself. A daemon that cannot has no
/// controller at all, which the server reports as `capabilityMissing`.
public protocol DaemonSelfUpdateControlling: AnyObject, Sendable {
    func startUpdate() -> DaemonSelfUpdateStartOutcome

    /// Persists `channel` and re-checks its feed right away.
    func setChannel(_ channel: DaemonUpdateChannel) throws
}
