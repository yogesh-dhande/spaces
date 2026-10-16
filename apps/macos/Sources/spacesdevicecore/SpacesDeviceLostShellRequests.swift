import Foundation

/// Asks the device to replace a shell that was lost without an exit (a reboot or a daemon crash) with a
/// fresh shell in the same workspace, directory and terminal row, under the lost shell's old output.
///
/// The device decides whether the session qualifies; a client sends this for any failed terminal session
/// it presents. The answer is a mutation result carrying the replacement's id in `sessionID` and the
/// session it replaced in `replacedSessionID`. A repeat or concurrent request for the same session is
/// answered with the same replacement.
public struct SpacesDeviceResumeLostShellRequest: Codable, Sendable, Equatable {
    public let sessionID: String

    public init(sessionID: String) { self.sessionID = sessionID }
}
