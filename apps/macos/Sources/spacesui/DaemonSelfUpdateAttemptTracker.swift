import Foundation
import spacesterminalcore

/// The Mac's record of the self-updates it asked devices to run, and the one place that turns a device's
/// status, reachability and that record into what the app shows (`DaemonSelfUpdatePresentation`).
///
/// A record carries the device's last status alongside the attempt because the status is dropped from
/// the sidebar the moment the device stops answering, and a restarting daemon is exactly that: without
/// the remembered status the Restarting and Still restarting states would have nothing to resolve from.
struct DaemonSelfUpdateAttemptTracker: Equatable {
    private struct Record: Equatable {
        var attempt: DaemonSelfUpdateAttempt
        var lastStatus: TerminalServiceDaemonStatus
        /// The channel from the last status that carried a self-update report, kept because the target
        /// build's status may carry none and the Updated block still names the channel.
        var lastChannel: DaemonUpdateChannel?
    }

    private var records: [String: Record] = [:]

    /// Whether an update this app started (or adopted from the daemon's own Restarting report) is still
    /// being followed for `deviceID`.
    func hasAttempt(deviceID: String) -> Bool { records[deviceID] != nil }

    /// The last status seen for a device with an attempt, so a block can still name its channel while the
    /// device is away.
    func lastStatus(deviceID: String) -> TerminalServiceDaemonStatus? { records[deviceID]?.lastStatus }

    /// The channel the device last reported following, for a device with an attempt.
    func lastChannel(deviceID: String) -> DaemonUpdateChannel? { records[deviceID]?.lastChannel }

    /// When a device that is restarting becomes Still restarting, or nil before it has been seen restarting.
    func stillRestartingDeadline(deviceID: String) -> Date? {
        records[deviceID]?.attempt.restartingSince.map { $0.addingTimeInterval(DaemonSelfUpdatePresentation.stillRestartingAfter) }
    }

    /// Records that the user asked `deviceID` to update to `targetVersion`.
    mutating func begin(deviceID: String, targetVersion: String, status: TerminalServiceDaemonStatus) {
        records[deviceID] = Record(
            attempt: DaemonSelfUpdateAttempt(targetVersion: targetVersion, fromVersion: status.version), lastStatus: status,
            lastChannel: status.selfUpdate?.channel)
    }

    /// Restarts the wait for a device to come back, for Try Again on a device that is still away.
    mutating func resetRestartingSince(deviceID: String, now: Date) {
        records[deviceID]?.attempt.restartingSince = now
    }

    mutating func forget(deviceID: String) { records[deviceID] = nil }

    /// Retires the record once its attempt has reached its target, which is what ends the Updated
    /// confirmation. An attempt still moving is left alone.
    mutating func dismissCompleted(deviceID: String) {
        guard let record = records[deviceID],
            !SpacesWireProtocol.isVersion(record.lastStatus.version, olderThan: record.attempt.targetVersion)
        else { return }
        records[deviceID] = nil
    }

    /// What to show for `deviceID`. Also advances the record: the first time the result is Restarting it
    /// stamps `restartingSince`, and a result of `.none` retires the record, so the two lifecycle edges
    /// live beside the one function every reader goes through. A completed attempt (`.updated`) keeps its
    /// record until `dismissCompleted`.
    ///
    /// Any in-flight report for a device with no record (the update was started elsewhere) adopts one, so
    /// this app still notices when the device does not come back. Adoption cannot wait for Restarting:
    /// the daemon hands off within a fraction of a second of the installer reaching that step, so a
    /// client that did not start the update rarely sees it reported before the device goes away.
    mutating func presentation(
        deviceID: String, liveStatus: TerminalServiceDaemonStatus?, isReachable: Bool, now: Date
    ) -> DaemonSelfUpdatePresentation {
        if let liveStatus, let record = records[deviceID] {
            records[deviceID] = Record(
                attempt: record.attempt.following(liveStatus), lastStatus: liveStatus, lastChannel: liveStatus.selfUpdate?.channel ?? record.lastChannel)
        }
        guard let status = liveStatus ?? records[deviceID]?.lastStatus else { return .none }

        let result = DaemonSelfUpdatePresentation.resolve(status: status, isReachable: isReachable, attempt: records[deviceID]?.attempt, now: now)
        if records[deviceID] == nil, let target = result.inFlightTargetVersion {
            records[deviceID] = Record(
                attempt: DaemonSelfUpdateAttempt(targetVersion: target, fromVersion: status.version), lastStatus: status,
                lastChannel: status.selfUpdate?.channel)
        }
        if result.isRestarting, records[deviceID]?.attempt.restartingSince == nil { records[deviceID]?.attempt.restartingSince = now }
        if result == .none { records[deviceID] = nil }
        return result
    }
}
