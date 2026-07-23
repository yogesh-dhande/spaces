import Foundation
import spacesclientcore
import spacesdevicecore

/// Process-wide single-flight for the GUI's local-device bootstrap — every pane-path call to
/// `bootstrapLocalDevice` (pane preparation and the models' in-session recoveries) routes through it.
///
/// Local pane events arrive in bursts: restoration prepares every pane at launch, and a
/// pairing-state reset drops every open pane's stream at nearly the same moment. Token-rotation
/// correctness is owned by `bootstrapLocalDevice` itself, which serializes concurrent bootstraps
/// process-wide (covering the sidebar, cold-resolve, and palette callers that do not route here);
/// this coalescing is the burst-efficiency layer on top — exactly one bootstrap round-trips the
/// control socket per pane burst instead of N serialized round-trips, and every concurrent caller
/// awaits it and installs the same refreshed record and token. All GUI models share one client-app
/// identity, so joiners receiving the initiator's bootstrap result is exact, not approximate.
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
                // pairing-state reset that minted a new token re-authenticates every sender. The
                // nested optional must be built explicitly: `try?` flattens a `throws -> String?`
                // result, which would report a thrown read as a successful "no token" and defeat
                // the callers' keep-previous-token fallback.
                let persistedToken: String??
                do { persistedToken = try SpacesDeviceCredentialStore.token(deviceID: SpacesPairedDeviceRecord.localDeviceID, profile: nil) } catch {
                    persistedToken = .none
                }
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
