import spacesdevicecore

/// Pure validation for a cross-device subscribe request, factored out of the daemon so it can be unit
/// tested with injected closures rather than a live paired device and network. Generic over the device
/// record type (the daemon passes its `SpacesPairedDeviceRecord`, tests pass a stub) so this stays in the
/// shared logic layer without depending on the client package. Fails loudly when the device is not paired
/// or the child terminal session has no agent session on it.
public enum RemoteAgentSubscriptionValidation {
    public static func validate<Device>(
        deviceID: String, childTerminalSessionID: String, resolveDevice: (String) throws -> Device?, deviceName: (Device) -> String,
        fetchRows: (Device) throws -> [SpacesDeviceAgentSessionRow]
    ) throws {
        guard let device = try resolveDevice(deviceID) else {
            throw WorkspaceError.invalidArgument(message: "No paired device \(deviceID). Pair it first with `spaces device pair`.")
        }
        guard try fetchRows(device).contains(where: { $0.terminalSessionID == childTerminalSessionID }) else {
            throw WorkspaceError.invalidArgument(
                message:
                    "No agent session for terminal \(childTerminalSessionID) on \(deviceName(device)). The remote child must have reported a lifecycle signal before it can be watched."
            )
        }
    }
}
