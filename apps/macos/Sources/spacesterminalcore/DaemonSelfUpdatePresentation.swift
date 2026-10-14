import Foundation

/// A client's own record of an update it asked one device to run. The daemon's progress describes the
/// run; this describes the client's wait for the device to come back.
public struct DaemonSelfUpdateAttempt: Equatable, Sendable {
    /// The version the attempt waits for. A client follows the daemon's reported run target (see
    /// `following(_:)`), so a retry that installs a different version still retires the attempt.
    public var targetVersion: String
    /// When the client first showed Restarting for this attempt; nil until it does.
    public var restartingSince: Date?

    public init(targetVersion: String, restartingSince: Date? = nil) {
        self.targetVersion = targetVersion
        self.restartingSince = restartingSince
    }

    /// This attempt retargeted to the run `status` reports, if it reports one. A retry after the device
    /// changed channel can install a lower version than the first try aimed at; keeping the old target
    /// would leave the client waiting forever for a version that is never coming.
    public func following(_ status: TerminalServiceDaemonStatus) -> DaemonSelfUpdateAttempt {
        guard let target = status.selfUpdate?.progress?.targetVersion else { return self }
        var attempt = self
        attempt.targetVersion = target
        return attempt
    }
}

/// What a client shows for one device's self-update, derived identically by the Mac and iPhone apps from
/// the daemon's last known status, whether it is reachable now, and the client's own attempt record.
public enum DaemonSelfUpdatePresentation: Equatable, Sendable {
    case none
    case available(from: String, to: String)
    case downloading(from: String, to: String, received: Int64, total: Int64?)
    case installing(from: String, to: String)
    case restarting(from: String, to: String)
    case stillRestarting(from: String, to: String)
    case failed(from: String, to: String, reason: String)

    /// How long a client waits in Restarting before saying the device is slow to return.
    public static let stillRestartingAfter: TimeInterval = 120

    /// - Parameters:
    ///   - status: the last status received from the device; it may be stale when `isReachable` is false.
    ///   - attempt: the client's record of an update it started, nil when it started none.
    public static func resolve(
        status: TerminalServiceDaemonStatus, isReachable: Bool, attempt: DaemonSelfUpdateAttempt?, now: Date
    ) -> DaemonSelfUpdatePresentation {
        guard let selfUpdate = status.selfUpdate else { return .none }
        let from = status.version

        // The device reports a version at or past the attempt's target: the attempt is over.
        if let attempt, !SpacesWireProtocol.isVersion(from, olderThan: attempt.targetVersion) { return .none }

        if let attempt, !isReachable, selfUpdate.progress?.step != .failed {
            return restarting(from: from, to: attempt.targetVersion, since: attempt.restartingSince, now: now)
        }

        if let progress = selfUpdate.progress {
            let to = progress.targetVersion
            switch progress.step {
            case .downloading:
                return .downloading(from: from, to: to, received: progress.receivedBytes ?? 0, total: progress.totalBytes)
            case .installing:
                return .installing(from: from, to: to)
            case .restarting:
                return restarting(from: from, to: to, since: attempt?.restartingSince, now: now)
            case .failed:
                return .failed(from: from, to: to, reason: progress.failureReason ?? DaemonSelfUpdateCopy.failedFallbackReason)
            }
        }

        // The client asked and the daemon has not reported the run yet (its next status is still in
        // flight): the run is starting, so offering Update again would invite a second press.
        if let attempt { return .downloading(from: from, to: attempt.targetVersion, received: 0, total: nil) }

        if let available = selfUpdate.availableVersion { return .available(from: from, to: available) }
        return .none
    }

    /// True while the presentation is Restarting.
    public var isRestarting: Bool {
        if case .restarting = self { return true }
        return false
    }

    /// Whether the device is moving through an update, so the app keeps polling it. Available is a
    /// standing offer and Failed waits for the user, so neither is.
    public var isInFlight: Bool {
        switch self {
        case .downloading, .installing, .restarting, .stillRestarting: true
        case .none, .available, .failed: false
        }
    }

    /// The version an in-flight step is moving the device to, nil for every other state.
    public var inFlightTargetVersion: String? {
        switch self {
        case .downloading(_, let to, _, _), .installing(_, let to), .restarting(_, let to), .stillRestarting(_, let to): to
        case .none, .available, .failed: nil
        }
    }

    private static func restarting(from: String, to: String, since: Date?, now: Date) -> DaemonSelfUpdatePresentation {
        if let since, now.timeIntervalSince(since) >= stillRestartingAfter { return .stillRestarting(from: from, to: to) }
        return .restarting(from: from, to: to)
    }
}
