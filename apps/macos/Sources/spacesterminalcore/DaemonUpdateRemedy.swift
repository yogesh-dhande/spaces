import Foundation

/// The action a client should offer a user about a device's daemon, derived from facts that device
/// reports about itself (`TerminalServiceDaemonStatus.protocolVersion`, and `installedVersion` versus
/// `version`) — never from comparing the daemon's version against this client's own build version. A
/// client and a given device's daemon ship on unrelated release trains, so that comparison is
/// meaningless: see the comment on `TerminalServiceDaemonStatus.isUpdatePending`.
///
/// Every Spaces client (macOS, iOS) computes this remedy the same way and renders it; none of them
/// re-derive the decision from raw compatibility/version fields independently.
public enum DaemonUpdateRemedy: Equatable, Sendable {
    /// Nothing to do: the daemon is compatible and no update is staged on its device.
    case none
    /// This client's own app build must update; the daemon is ahead of it.
    case updateClient
    /// A newer build is installed on the daemon's device and a restart applies it in place.
    /// `installedVersion` is the staged build's version — every consumer needs it for its copy, so it
    /// travels with the case instead of being re-derived (and re-force-unwrapped) at each call site.
    case applyStagedUpdate(installedVersion: String)
    /// The daemon is incompatible and nothing newer is staged on its device; a restart would re-exec
    /// the same binary and leave the warning unresolved. The user must install a newer Spaces on that
    /// device first.
    case installUpdateOnDevice

    /// The only remedy for which offering a "restart daemon" / "update" action makes sense. A restart
    /// re-execs whatever build is installed on the device: with a staged update it applies it, but with
    /// nothing staged it is a guaranteed no-op, so every other remedy must not surface that action.
    public var offersDaemonUpdateAction: Bool {
        if case .applyStagedUpdate = self { return true }
        return false
    }

    /// Decides what a client should offer the user about `status`'s device.
    ///
    /// Order matters:
    /// 1. If this client is behind the daemon's wire protocol, the client app must update — restarting
    ///    the daemon (even onto a staged build) only widens that gap, so this check runs first.
    /// 2. If the device has a newer build staged (`isUpdatePending`), a restart applies it. This is the
    ///    sole state that yields `.applyStagedUpdate` and therefore the sole state in which a client may
    ///    offer a daemon-update/restart action. `installedVersion == nil` (a daemon launched from a
    ///    development build directory) makes `isUpdatePending` false, so a dev daemon correctly yields no
    ///    action — there is no installed build to apply.
    /// 3. If the daemon is otherwise too old and nothing is staged, the user must install a newer Spaces
    ///    on that device; nothing this client does can fix it remotely.
    /// 4. Otherwise the daemon is compatible and up to date.
    public static func remedy(for status: TerminalServiceDaemonStatus) -> DaemonUpdateRemedy {
        let compatibility = SpacesWireCompatibility.evaluate(daemonStatus: status)
        if compatibility == .clientTooOld { return .updateClient }
        if let stagedVersion = status.stagedVersion { return .applyStagedUpdate(installedVersion: stagedVersion) }
        if compatibility == .daemonTooOld { return .installUpdateOnDevice }
        return .none
    }
}
