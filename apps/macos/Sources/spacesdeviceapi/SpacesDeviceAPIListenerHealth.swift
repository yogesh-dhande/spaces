import Foundation

/// Decides whether a started Device API listener still counts as running.
///
/// The listener reports a waiting state when it cannot take its port or its interface is
/// unavailable. That is frequently transient and self-resolving — an exiting process still holding
/// the port, an interface coming back — so a waiting listener is tolerated for
/// `waitingGracePeriod`. Past it the wait is treated as permanent and the server reports as not
/// running, which is what `SpacesDeviceAPISupervisor`'s health check uses to tear the listener down
/// and build a fresh one. Without this a stuck wait is silent and permanent: the listener accepts
/// nothing while the daemon keeps reporting itself as up.
enum SpacesDeviceAPIListenerHealth {
    /// How long the listener may stay in the waiting state before it counts as down. Several
    /// supervisor health checks fit inside it, so a wait that resolves on its own is never
    /// interrupted by a rebuild.
    static let waitingGracePeriod: TimeInterval = 20

    static func isRunning(listenerStarted: Bool, waitingSince: Date?, now: Date) -> Bool {
        guard listenerStarted else { return false }
        guard let waitingSince else { return true }
        return now.timeIntervalSince(waitingSince) < waitingGracePeriod
    }
}
