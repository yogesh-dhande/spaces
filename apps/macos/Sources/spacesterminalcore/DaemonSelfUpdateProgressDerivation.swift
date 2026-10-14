import Foundation

/// Turns the update runner's log into the progress a daemon reports.
///
/// The runner is the bundled installer, which prints machine-readable `spaces-install-linux: step ...`
/// lines as it moves through its phases and, on a failure, a human sentence on a
/// `spaces-install-linux: <message>` line. The runner wrapper appends `step exited <status>` when the
/// installer returns. The log, not process state, is the source of truth because the runner lives in its
/// own systemd unit and outlives the daemon image that launched it.
public enum DaemonSelfUpdateProgressDerivation {
    static let linePrefix = "spaces-install-linux: "

    public struct Result: Equatable, Sendable {
        /// What to report; nil when no run is worth showing.
        public let progress: DaemonSelfUpdateProgress?
        /// True when the running version has reached the target, so the run's state is spent and the
        /// daemon should delete it.
        public let isRunSpent: Bool
    }

    /// - Parameters:
    ///   - logText: the runner's log so far.
    ///   - archiveSize: the current size in bytes of the archive path a `downloading` line names, nil
    ///     when it does not exist yet.
    public static func derive(
        logText: String, targetVersion: String, runningVersion: String, archiveSize: (String) -> Int64?
    ) -> Result {
        // A daemon already on the target (or past it) has nothing in flight, whatever the log says.
        if !SpacesWireProtocol.isVersion(runningVersion, olderThan: targetVersion) { return Result(progress: nil, isRunSpent: true) }

        var lastStep: [Substring]?
        // The failure reason is the last line before `exited`, whoever printed it: the installer's own
        // `die` sentences carry the prefix, while the bundled install.sh reports its failures unprefixed.
        // Only the last line counts, so an earlier informational line is never mistaken for the reason.
        var lastMessage: String?
        for line in logText.split(whereSeparator: \.isNewline) {
            let body = line.hasPrefix(linePrefix) ? line.dropFirst(linePrefix.count) : line[...]
            if line.hasPrefix(linePrefix), body.hasPrefix("step ") {
                let fields = body.dropFirst("step ".count).split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                if fields.first != "exited" { lastMessage = nil }
                lastStep = fields
            } else if !body.trimmingCharacters(in: .whitespaces).isEmpty {
                lastMessage = String(body)
            }
        }

        // A launched run that has printed nothing yet is still fetching the manifest, which reads as the
        // start of the download.
        guard let lastStep, let name = lastStep.first else {
            return Result(
                progress: DaemonSelfUpdateProgress(targetVersion: targetVersion, step: .downloading, receivedBytes: 0, totalBytes: nil),
                isRunSpent: false)
        }
        func progress(_ step: DaemonSelfUpdateProgress.Step, received: Int64? = nil, total: Int64? = nil, reason: String? = nil)
            -> DaemonSelfUpdateProgress
        {
            DaemonSelfUpdateProgress(targetVersion: targetVersion, step: step, receivedBytes: received, totalBytes: total, failureReason: reason)
        }

        switch name {
        case "downloading":
            let total = lastStep.count > 1 ? Int64(lastStep[1]) : nil
            let path = lastStep.count > 2 ? String(lastStep[2]) : nil
            let received = path.flatMap(archiveSize) ?? 0
            return Result(progress: progress(.downloading, received: received, total: total), isRunSpent: false)
        case "installing":
            return Result(progress: progress(.installing), isRunSpent: false)
        case "restarting":
            return Result(progress: progress(.restarting), isRunSpent: false)
        case "exited":
            let status = lastStep.count > 1 ? Int(lastStep[1]) : nil
            // A clean exit leaves a staged build for the existing staged-update path to apply, so there is no
            // self-update progress left to report.
            if status == 0 { return Result(progress: nil, isRunSpent: false) }
            let reason = lastMessage.map(sentence) ?? "The installer exited with status \(status.map(String.init) ?? "unknown")."
            return Result(progress: progress(.failed, reason: reason), isRunSpent: false)
        default:
            return Result(progress: nil, isRunSpent: false)
        }
    }

    /// The failure a restarted daemon reports for a run that never wrote `exited`: the version is still
    /// old, the runner's unit is gone, and nothing will finish the job.
    public static func recoveredProgress(
        logText: String, targetVersion: String, runningVersion: String, runnerUnitIsActive: Bool
    ) -> DaemonSelfUpdateProgress? {
        guard SpacesWireProtocol.isVersion(runningVersion, olderThan: targetVersion), !runnerUnitIsActive else { return nil }
        let hasExited = logText.split(whereSeparator: \.isNewline).contains { $0.hasPrefix(linePrefix + "step exited") }
        guard !hasExited else { return nil }
        return DaemonSelfUpdateProgress(
            targetVersion: targetVersion, step: .failed, failureReason: DaemonSelfUpdateCopy.failedFallbackReason)
    }

    private static func sentence(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return trimmed }
        return first.uppercased() + trimmed.dropFirst()
    }
}
