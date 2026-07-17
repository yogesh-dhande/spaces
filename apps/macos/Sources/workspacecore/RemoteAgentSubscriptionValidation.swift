import spacesdevicecore

/// Pure validation for a cross-device subscribe request, factored out of the daemon so it can be unit
/// tested with injected closures rather than a live paired device and network. Generic over the device
/// record type (the daemon passes its `SpacesPairedDeviceRecord`, tests pass a stub) so this stays in the
/// shared logic layer without depending on the client package. Fails loudly when the device is not paired
/// or the child terminal session has no agent session on it.
///
/// Returns the matched `SpacesDeviceAgentSessionRow` — the child's current listing row as of validation.
/// The daemon seeds it into the watch baseline before the edge goes live, so a transition (or an exit)
/// that lands between this fetch and the watch's first listing is diffed against a real prior state
/// instead of being silently absorbed into a fresh baseline.
public enum RemoteAgentSubscriptionValidation {
    public static func validate<Device>(
        deviceID: String, childTerminalSessionID: String, resolveDevice: (String) throws -> Device?, deviceName: (Device) -> String,
        fetchRows: (Device) throws -> [SpacesDeviceAgentSessionRow]
    ) throws -> SpacesDeviceAgentSessionRow {
        guard let device = try resolveDevice(deviceID) else {
            throw WorkspaceError.invalidArgument(message: "No paired device \(deviceID). Pair it first with `spaces device pair`.")
        }
        guard let matched = try fetchRows(device).first(where: { $0.terminalSessionID == childTerminalSessionID }) else {
            throw WorkspaceError.invalidArgument(
                message:
                    "No agent session for terminal \(childTerminalSessionID) on \(deviceName(device)). The remote child must have reported a lifecycle signal before it can be watched."
            )
        }
        return matched
    }
}
