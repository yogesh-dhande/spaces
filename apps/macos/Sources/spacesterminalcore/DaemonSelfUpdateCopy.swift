import Foundation

/// The self-update wording both clients render, so the Mac and iPhone state the same facts the same way.
public enum DaemonSelfUpdateCopy {
    public static let availableTitle = "Update available"
    public static let tryAgainTitle = "Try Again"
    public static let downloadingFootnote = "Safe to leave this screen."
    public static let stillRestartingTitle = "Still restarting"
    public static let failedTitle = "Update didn't finish"
    /// Shown for a failed run whose daemon reported no reason.
    public static let failedFallbackReason = "The update stopped before it finished."

    public static let updatedTitle = "Updated"
    public static let updateButtonTitle = "Update"

    public static func availableBody(version: String) -> String {
        "Spaces \(version) is out. The device updates itself, and nothing it's running stops."
    }

    public static func updatedBody(version: String) -> String { "Running Spaces \(version). Its terminals kept running." }

    public static func downloadingTitle(deviceName: String) -> String { "Updating \(deviceName)" }

    /// "Downloading 12.4 of 38.0 MB", or "Downloading 12.4 MB" when the total is unknown.
    public static func downloadingDetail(received: Int64, total: Int64?) -> String {
        if let total { return "Downloading \(megabytes(received)) of \(megabytes(total)) MB" }
        return "Downloading \(megabytes(received)) MB"
    }

    public static func installingBody(version: String) -> String { "Checking the signature and installing \(version)." }

    public static func restartingBody(version: String) -> String { "Restarting on \(version). Its terminals keep running." }

    public static func stillRestartingBody(version: String) -> String {
        "The device hasn't come back on \(version) yet. Its terminals keep running."
    }

    // MARK: - Mac detail block

    public static func macWhoLine(deviceName: String, channel: DaemonUpdateChannel) -> String {
        switch channel {
        case .stable: "\(deviceName) · stable releases"
        case .prerelease: "\(deviceName) · pre-release updates"
        }
    }

    public static func macBody(version: String) -> String {
        "The device downloads and installs Spaces \(version) itself. Nothing it's running stops."
    }

    // MARK: - iPhone blocked hero

    public static func heroWhoLine(availableVersion: String, deviceName: String) -> String { "\(availableVersion) is available for \(deviceName)" }

    public static let heroBody = "The device downloads and installs it itself. Nothing it's running stops."

    /// A blocked device that can update itself but has not found a release to update to yet.
    public static let noReleaseFoundBody = "The device checks for a newer Spaces release on its own and offers Update here once it finds one."

    /// Decimal megabytes with one decimal place.
    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000)
    }
}
