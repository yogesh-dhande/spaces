import Foundation

/// The line between a lost shell's old transcript and the replacement shell that continues below it.
///
/// It names why the old shell ended and when it last showed output, so a reader scrolling up knows the
/// text above is history and not a live session.
public enum TerminalLostShellSeparator {
    public enum HostPlatform: Sendable, Equatable {
        case mac
        case linux

        /// The platform this process runs on, which is the platform of the daemon hosting the shell.
        public static var current: HostPlatform {
            #if os(macOS)
                .mac
            #else
                .linux
            #endif
        }
    }

    public enum Cause: Sendable, Equatable {
        /// The host booted after the shell last showed output.
        case hostRestarted(HostPlatform)
        /// The host stayed up, so only the daemon went away.
        case spacesStoppedUnexpectedly

        var phrase: String {
            switch self {
            case .hostRestarted(.mac): "when the Mac restarted"
            case .hostRestarted(.linux): "when the computer restarted"
            case .spacesStoppedUnexpectedly: "when Spaces stopped unexpectedly"
            }
        }
    }

    /// A boot time later than the shell's last output means the host rebooted while the shell was alive.
    /// An unreadable boot time claims nothing, so it reads as the daemon stopping.
    public static func cause(lastOutputAt: Date, hostBootedAt: Date?, platform: HostPlatform) -> Cause {
        guard let hostBootedAt, hostBootedAt > lastOutputAt else { return .spacesStoppedUnexpectedly }
        return .hostRestarted(platform)
    }

    /// The separator text, without terminal styling. The time uses the daemon's zone because the daemon is
    /// the host the shell lived on, and a fixed POSIX locale keeps the text identical on every machine.
    public static func text(cause: Cause, lastOutputAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d, h:mm a"
        return "Shell ended \(cause.phrase) \u{00B7} \(formatter.string(from: lastOutputAt)) \u{00B7} new shell below"
    }
}
