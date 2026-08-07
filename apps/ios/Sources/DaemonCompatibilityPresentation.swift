import Foundation
import spacesterminalcore

/// The two versions a daemon-version state spans: the build that is running now, and the build that
/// closes the gap. `from` is always the side that has to move, so it renders muted and `to` carries the
/// emphasis; the states differ only in whose versions these are, which the who-line says. Mirrors the
/// Mac block's pair so both clients say the same thing the same way.
struct DaemonVersionPair: Equatable {
    let from: String
    let to: String

    /// Stands in for a version this state has no fact for: the target when what lands is whatever the
    /// user installs on the device. An honest hole beats a number the app would have to invent.
    static let unknown = "?"
}

/// What the device screen says about the active device's daemon version, decided in one pure place so
/// the decision is unit-testable without a SwiftUI hierarchy and the two renderings cannot disagree
/// about which state they are in.
///
/// The rule the shape encodes: the app shows something only where the user must act, or must be told
/// something did not happen.
/// - A compatible device with a build staged gets a quiet card and keeps its rows: the phone may be the
///   only client running, so it keeps the explicit action here (the Mac applies staged updates on its
///   own, but only while it is running).
/// - A blocked device gets the hero, which replaces the screen's content, because nothing else on that
///   screen can be used.
/// - A blocked device whose staged build the app is applying by itself gets `.none` while that is under
///   way: work already in flight is not something to look at. The hero for that state appears only once
///   the apply did not land (`stagedApplyDidNotLand`).
enum DaemonCompatibilityPresentation: Equatable {
    case none
    case pendingUpdate(PendingUpdate)
    case hero(Hero)

    /// The compact card for a device that works fine and has an update waiting.
    struct PendingUpdate: Equatable {
        let title: String
        /// Small trailing pair, the same `running → staged` fact the hero states large.
        let versionPair: DaemonVersionPair
        let body: String
        let actionTitle: String
    }

    /// The full-screen version hero for a device this app cannot use.
    struct Hero: Equatable {
        /// Uppercase orange label naming the state: the one place severity lives, so no warning icon and
        /// no orange frame are needed.
        let eyebrow: String
        /// The version gap itself, the screen's largest element.
        let versionPair: DaemonVersionPair
        /// Quiet line under the pair saying whose versions those are.
        let whoLine: String
        /// One sentence: what happens next, in the user's terms.
        let body: String
        /// `nil` for every state nothing this app does can fix.
        let actionTitle: String?
    }

    /// Builds the presentation for the active device.
    ///
    /// `clientVersion` never decides anything below: `remedy` already encodes every decision, and a
    /// client must never re-derive one by comparing its own build against a daemon's (this app and a
    /// given device's daemon ship on unrelated release trains — see `DaemonUpdateRemedy`). It appears
    /// only as one named side of the `.updateClient` pair, which is a statement of the two builds in
    /// play, not a comparison.
    ///
    /// `isBlocked` is the wire verdict, needed for exactly one thing: `.applyStagedUpdate` is the sole
    /// remedy that arises in both a blocking and a non-blocking state, and only the verdict tells them
    /// apart. `.updateClient` and `.installUpdateOnDevice` are produced only from an incompatible
    /// verdict, so they are always the blocking hero.
    static func presentation(
        remedy: DaemonUpdateRemedy, status: TerminalServiceDaemonStatus, isBlocked: Bool, stagedApplyDidNotLand: Bool, deviceName: String,
        clientVersion: String
    ) -> DaemonCompatibilityPresentation {
        let runningVersion = displayVersion(status.version)
        switch remedy {
        case .none: return .none

        case .updateClient:
            return .hero(
                Hero(
                    eyebrow: "CAN'T CONNECT — THIS APP NEEDS AN UPDATE",
                    versionPair: DaemonVersionPair(from: displayVersion(clientVersion), to: runningVersion), whoLine: "this app · \(deviceName)",
                    body: "\(deviceName) speaks a newer connection protocol than this app. Update Spaces from the App Store to reconnect.",
                    actionTitle: nil))

        case .applyStagedUpdate(let stagedVersion):
            let pair = DaemonVersionPair(from: runningVersion, to: stagedVersion)
            guard isBlocked else {
                return .pendingUpdate(
                    PendingUpdate(
                        title: "Update pending", versionPair: pair,
                        body: "Spaces \(stagedVersion) is on \(deviceName), ready to apply. Nothing it's running stops.", actionTitle: "Update Daemon"
                    ))
            }
            // Withheld while the app is applying the staged build by itself: the device passes through
            // the ordinary seconds-long reconnect and comes back, so there is nothing to act on and
            // nothing that did not happen.
            guard stagedApplyDidNotLand else { return .none }
            // The wording never calls the apply a failure: a daemon that is slow to restart and one that
            // refused look identical from here, so this reports what has not happened.
            return .hero(
                Hero(
                    eyebrow: "CAN'T CONNECT — UPDATE READY TO APPLY", versionPair: pair,
                    whoLine: "Spaces \(stagedVersion) is already on \(deviceName)",
                    body: "Its daemon didn't pick the update up, and nothing running on \(deviceName) was interrupted.", actionTitle: "Update Daemon")
            )

        case .installUpdateOnDevice:
            // Nothing is staged, so there is no target version to name: what lands is whatever gets
            // installed on the device, from the Mac app over SSH or by opening Spaces there.
            return .hero(
                Hero(
                    eyebrow: "CAN'T CONNECT — UPDATE NEEDED", versionPair: DaemonVersionPair(from: runningVersion, to: DaemonVersionPair.unknown),
                    whoLine: "nothing newer is installed on \(deviceName)",
                    body: status.isLinuxDaemon
                        ? "Update it from Spaces on your Mac — it installs over SSH, and everything on \(deviceName) keeps running. This phone "
                            + "can't update a Linux daemon."
                        : "Open Spaces on \(deviceName) and install the update; its daemon applies it on its own, and nothing running stops.",
                    actionTitle: nil))
        }
    }

    /// A version string the app has no value for renders as the same honest hole an absent target does,
    /// rather than as a blank gap in the pair. `TerminalServiceDaemonStatus.version` decodes to an empty
    /// string when a peer omits it, which is exactly the case with no fact to state.
    private static func displayVersion(_ version: String) -> String { version.isEmpty ? DaemonVersionPair.unknown : version }
}
