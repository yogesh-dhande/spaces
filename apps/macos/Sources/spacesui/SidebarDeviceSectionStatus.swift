import Foundation

/// What a device section header renders next to the device name: the section's load state, the action
/// that recovers it, or nothing.
///
/// An offline device that can be retried renders the button alone. The button *is* the status: a red
/// "offline" caption beside a button that recovers the device stated the same fact twice, so one tinted
/// control both reports the outage and acts on it, and it carries the failure reason as its tooltip.
/// An offline device with no action to offer — a remote whose stored credentials are gone, recovered by
/// pairing it again — has no button to carry the status, so it keeps a caption instead.
enum SidebarDeviceSectionStatus: Equatable {
    /// Quiet trailing caption text. `isFailure` selects the failed tint over the muted one.
    case caption(text: String, isFailure: Bool)
    /// An inline button, tinted as a problem state, that both reports the outage and recovers from it.
    case recoveryButton(title: String)
    case none
}

extension SidebarDeviceSectionStatus {
    /// Resolves a device section's caption area from the facts the sidebar holds about it. Pure, so the
    /// caption-versus-button decision is testable without an outline view.
    ///
    /// An incompatible device is not represented here: its header renders the compatibility action
    /// instead, decided by the cell before this is consulted.
    static func resolve(loadState: AppKitController.SidebarDeviceLoadState, isLocal: Bool, offersRetry: Bool, isUpdatePending: Bool) -> Self {
        switch loadState {
        case .loading: return .caption(text: "loading…", isFailure: false)
        case .offline:
            // You cannot reconnect to the machine the app runs on — an offline local device means its own
            // daemon is down and needs relaunching, which is what its retry does. The wording matches the
            // refusal the same device gives an action reached by shortcut.
            guard offersRetry else { return .caption(text: "offline", isFailure: true) }
            return .recoveryButton(title: isLocal ? "Restart" : "Reconnect")
        // A device with a newer build installed than its daemon is running shows a quiet caption; it is
        // reachable and fully usable, so nothing here is actionable.
        case .loaded: return isUpdatePending ? .caption(text: "update pending", isFailure: false) : .none
        }
    }
}
