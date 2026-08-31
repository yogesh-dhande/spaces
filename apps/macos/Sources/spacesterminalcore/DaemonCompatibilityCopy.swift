import Foundation

/// The two versions a daemon-compatibility state spans: the build that is running now, and the build
/// that closes the gap. `from` is always the side that has to move, so it renders muted and `to` carries
/// the emphasis; the states differ only in whose versions these are, which the who-line says. Shared by
/// both clients so their version heroes state the same two numbers the same way.
public struct DaemonVersionPair: Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// Stands in for a version a state has no fact for: the target when what lands is whatever the user
    /// installs on the device, or a daemon version this app never received. An honest hole beats a number
    /// the app would have to invent.
    public static let unknown = "?"

    /// A version string with no fact behind it (an empty wire value — `TerminalServiceDaemonStatus.version`
    /// decodes to one when a peer omits it) renders as `unknown` rather than as a blank gap in the pair.
    public static func displayVersion(_ version: String) -> String { version.isEmpty ? unknown : version }
}

/// The daemon-compatibility copy that reads byte-for-byte identically on macOS and iOS because both
/// clients state it the same way for the same facts: the eyebrow naming a state, and the who-line and
/// body under it, for the two states whose wording has not drifted between the clients. This is the
/// single derivation both clients render for that copy.
///
/// Everything that legitimately differs per client stays in each client's own presentation code instead:
/// the platform's own wording for how to install an update (this Mac's Sparkle/SSH-install guidance vs.
/// an iOS App Store nudge, which differ because the platforms differ in how an update actually lands),
/// the per-remedy action title (e.g. "Try Again" on the Mac vs. "Update Daemon" on iOS), layout, and SF
/// Symbols.
public enum DaemonCompatibilityCopy {
    // MARK: - `.updateClient` (this client's own build is behind the daemon's wire protocol)

    public static let updateClientEyebrow = "CAN'T CONNECT — THIS APP NEEDS AN UPDATE"

    public static func updateClientWhoLine(deviceName: String) -> String { "this app · \(deviceName)" }

    // MARK: - `.applyStagedUpdate`, blocked (a staged build didn't land after being asked to apply)

    public static let stagedUpdateNotLandedEyebrow = "CAN'T CONNECT — UPDATE READY TO APPLY"

    public static func stagedUpdateNotLandedWhoLine(installedVersion: String, deviceName: String) -> String {
        "Spaces \(installedVersion) is already on \(deviceName)"
    }

    /// The wording never calls the apply a failure: a daemon that is slow to restart and one that refused
    /// look identical from here, so this reports what has not happened.
    public static func stagedUpdateNotLandedBody(deviceName: String) -> String {
        "Its daemon didn't pick the update up, and nothing running on \(deviceName) was interrupted."
    }
}
