import Foundation
import spacesclientcore
import spacesdevicecore

/// Process-wide single-flight for the local-device recovery bootstrap.
///
/// After a local pairing-state reset, every open local pane's recovery fires at nearly the same
/// moment. `SpacesDevicePairingStore.issueToken` mints a replacement token for every stale
/// presentation, so N concurrent bootstraps would invalidate each other's freshly installed tokens
/// and out-of-order secret-file saves could persist a non-current token. Coalescing means exactly
/// one bootstrap round-trips the control socket; every concurrent recovery awaits it and installs
/// the same refreshed record and token. All GUI models share one client-app identity, so joiners
/// receiving the initiator's bootstrap result is exact, not approximate.
@MainActor enum LocalDeviceRecoveryBootstrap {
    struct Outcome {
        let record: SpacesPairedDeviceRecord
        /// The persisted-token read: `.some(value)` when the read succeeded (`value` may be nil —
        /// a legitimate "no token"), `nil` when the read itself failed. Callers apply their own
        /// keep-previous-token fallback to a failed read so a transient secret-store hiccup does
        /// not drop auth.
        let persistedToken: String??
    }

    private static var inflight: Task<Outcome?, Never>?

    /// Runs (or joins) the shared bootstrap. Returns nil when the bootstrap itself failed.
    static func run(clientApp: SpacesDeviceClientApp) async -> Outcome? {
        if let inflight { return await inflight.value }
        let task = Task<Outcome?, Never> {
            await Task.detached(priority: .userInitiated) { () -> Outcome? in
                guard let refreshed = try? SpacesDeviceClient.bootstrapLocalDevice(clientApp: clientApp) else { return nil }
                // The bootstrap persisted the daemon's (possibly rotated) token; read it back so a
                // pairing-state reset that minted a new token re-authenticates every sender.
                let persistedToken: String?? = try? SpacesDeviceCredentialStore.token(
                    deviceID: SpacesPairedDeviceRecord.localDeviceID, profile: nil)
                return Outcome(record: refreshed, persistedToken: persistedToken)
            }.value
        }
        inflight = task
        let outcome = await task.value
        // Joiners return through the early branch above and never write `inflight`, so only the
        // initiator reaches this line and the clear cannot stomp a newer flight.
        inflight = nil
        return outcome
    }
}
