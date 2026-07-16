import spacesdevicecore

/// Handle to one open device-overview stream held by the remote agent watch; the service only ever
/// stops it. The daemon's live transport wraps `SpacesDeviceAPIOverviewStreamClient`; tests
/// substitute a recorder.
public protocol RemoteAgentOverviewStreamHandle: Sendable {
    func stop()
}

/// Outcome of dialing a paired device's overview stream on behalf of the remote agent watch.
public enum RemoteAgentWatchConnectResult: Sendable {
    /// The stream is up: overview pushes arrive through `onSignal` until `onDisconnect` fires.
    case connected(any RemoteAgentOverviewStreamHandle)
    /// The device is no longer paired, so its watch edges can never be served again.
    case deviceUnpaired
    /// Transient failure (missing credentials, unreachable device); the watch retries later.
    case unavailable(reason: String)
}

/// The network seam of `RemoteAgentWatchService`, keyed by paired-device id so the service carries
/// no client-database or TLS-credential knowledge and stays testable from workspacecore. The daemon
/// injects the live device-client implementation; tests inject fakes to drive
/// connect/disconnect/listing sequences.
public struct RemoteAgentWatchTransport: Sendable {
    /// Resolves the paired device and dials its overview stream. Blocking; called off the main actor.
    public var connect:
        @Sendable (
            _ deviceID: String, _ onSignal: @escaping @Sendable () -> Void, _ onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) -> RemoteAgentWatchConnectResult
    /// Pulls the device's current coding-agent session listing. Blocking; called off the main actor.
    public var listAgentSessions: @Sendable (_ deviceID: String) throws -> [SpacesDeviceAgentSessionRow]

    public init(
        connect: @escaping @Sendable (
            _ deviceID: String, _ onSignal: @escaping @Sendable () -> Void, _ onDisconnect: @escaping @Sendable ((any Error)?) -> Void
        ) -> RemoteAgentWatchConnectResult,
        listAgentSessions: @escaping @Sendable (_ deviceID: String) throws -> [SpacesDeviceAgentSessionRow]
    ) {
        self.connect = connect
        self.listAgentSessions = listAgentSessions
    }
}
