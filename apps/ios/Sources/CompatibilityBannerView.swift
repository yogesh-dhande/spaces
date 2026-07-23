import SwiftUI
import spacesterminalcore

/// Renders the action a user can take about a device's daemon. The decision of *what* to offer already
/// happened in `DaemonUpdateRemedy.remedy(for:)`; this view only renders `remedy`'s case and reads
/// `status`'s fields for display copy (concrete versions, Linux guidance) and to tell apart the two
/// shapes `.applyStagedUpdate` can take (see `isBlocking`). It never derives a decision of its own from
/// `status`.
///
/// - `.applyStagedUpdate` renders in both a blocking flavor (the daemon is also wire-incompatible) and a
///   quiet, non-blocking flavor (the daemon is compatible; the update is merely staged) — both route
///   through this one view so there is a single source of the "update the daemon to apply it" copy and
///   action, rather than a separate ad hoc rendering for the pending case.
/// - `.updateClient` and `.installUpdateOnDevice` show no action button: nothing this app does can fix
///   either remotely.
/// - `.none` is never expected to reach this view; the call site does not present a banner for it.
struct CompatibilityBannerView: View {
    let remedy: DaemonUpdateRemedy
    let status: TerminalServiceDaemonStatus
    let isMutating: Bool
    let onUpdate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isBlocking ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath").foregroundStyle(
                    isBlocking ? Theme.orange : Theme.accent)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.mutedSecondary).fixedSize(horizontal: false, vertical: true)
            if remedy.offersDaemonUpdateAction {
                Button(action: onUpdate) {
                    Text("Update Daemon").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.borderedProminent).tint(isBlocking ? Theme.orange : Theme.accent).disabled(isMutating)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        ).overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((isBlocking ? Theme.orange : Theme.accent).opacity(0.5), lineWidth: 1)
        )
    }

    /// Whether this state also blocks normal use of the device (wire-incompatible), as opposed to
    /// `.applyStagedUpdate`'s other, non-blocking shape where the daemon is fully compatible and the
    /// update is merely staged. `DaemonUpdateRemedy.remedy(for:)` already ran this exact wire-protocol
    /// compatibility check as its first step; recomputing it here from `status` selects which visual
    /// treatment an already-decided remedy gets — it does not change what action is offered.
    ///
    /// Not `private`: the unit test suite reads this (and `title`/`detail` below) directly off a
    /// constructed view to check the remedy-to-copy mapping without standing up a SwiftUI hierarchy.
    var isBlocking: Bool { SpacesWireCompatibility.evaluate(daemonStatus: status) != .compatible }

    /// A Linux daemon can only be updated from the Spaces Mac app (over SSH); this app can request a
    /// restart but cannot refresh the binary, so Linux guidance always points at the Mac.
    private var isLinuxDaemon: Bool { status.isLinuxDaemon }

    var title: String {
        switch remedy {
        case .updateClient: "Update Spaces to use this device"
        case .installUpdateOnDevice: isLinuxDaemon ? "Update this device from your Mac" : "Install the update on this device"
        case .applyStagedUpdate: isBlocking ? "This device needs a daemon update" : "Daemon update pending"
        case .none: ""
        }
    }

    // Version numbers below are shown purely as context for the user's next action — which machine to
    // go update. They never drive the button's presence, the title, or the severity above: all three
    // already came from `remedy`/`isBlocking`, computed solely from `status`'s own fields. In
    // particular, this app's own version (`MobileAppVersion.current`) is never compared against a
    // daemon's version to decide anything: this app and a given device's daemon ship on unrelated
    // release trains, so that comparison would be meaningless.
    var detail: String {
        switch remedy {
        case .updateClient:
            "This device is running Spaces \(status.version), newer than this app's Spaces \(MobileAppVersion.current). Update the app from the "
                + "App Store to reconnect."
        case .installUpdateOnDevice:
            isLinuxDaemon
                ? "This device's daemon is running Spaces \(status.version) and has no newer build installed to restart into. Update it from the "
                    + "Spaces app on your Mac — this app can't update a Linux daemon directly. Running terminals, agents, and processes on it are "
                    + "preserved. It reconnects once updated."
                : "This device's daemon is running Spaces \(status.version) and has no newer build installed to restart into. Open Spaces on it "
                    + "and install the update. Running terminals, agents, and processes on it are preserved. It reconnects once updated."
        case .applyStagedUpdate(let installedVersion):
            isBlocking
                ? "Spaces \(installedVersion) is installed on this device, ahead of the daemon's Spaces \(status.version). Update the daemon to "
                    + "apply it and reconnect — running terminals, agents, and processes are preserved."
                : "Spaces \(installedVersion) is installed on this device; the daemon keeps running Spaces \(status.version) until it updates. "
                    + "Running terminals, agents, and processes are preserved through the update."
        case .none: ""
        }
    }
}
