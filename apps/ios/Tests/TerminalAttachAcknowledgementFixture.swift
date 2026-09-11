#if canImport(UIKit)
    import Foundation
    import spacesdevicecore
    import spacesterminalcore

    /// The answer the daemon gives an attach, for every fixture that has to stand in for one.
    ///
    /// `.attach` is one of the controls whose answer carries the post-control session state
    /// (`TerminalControlCommand.includesSessionStateOnSuccess`), and that state is where the attachment the
    /// attach just made is named. A bare `ok` is not a neutral stand-in for it — it is the exceptional
    /// answer of a daemon whose post-control state load failed, which the viewer recovers from by reading
    /// the state itself, so a fixture answering that way makes every attach cost a read it would not cost
    /// on a device. Every suite that means "the attach succeeded" therefore answers through here, and a
    /// fixture that wants the exceptional answer says so explicitly.
    ///
    /// The client row it names carries the daemon's own attach-lease stamp rather than the `connectedAt`
    /// the client sent: the macOS daemon replaces that field for every client whose liveness its lease
    /// decides (`GhosttyEmbeddedSessionHost.clientForAttachLease`), so a fixture echoing the request back
    /// would model only the headless daemon, and would let a viewer that remembered what it sent pass tests
    /// it must fail. The stamp is distinct for every attach, with the sub-second precision the daemon mints
    /// it at, so two attaches milliseconds apart are two identities here exactly as they are on a device.
    enum TerminalAttachAcknowledgementFixture {
        /// The acknowledgement for `request` when it is an attach, and nil for every other request, so a
        /// transport can front its own answers with it:
        /// `if let ack = TerminalAttachAcknowledgementFixture.acknowledgement(for: request) { return ack }`.
        static func acknowledgement(for request: SpacesDeviceAPIRequest, emittedAt: String = "2026-06-04T14:23:31Z") -> SpacesDeviceAPIResponse? {
            guard case .terminalControl(let control) = request.command, control.action == .attach, let client = control.client else { return nil }
            let attached = TerminalClient(id: client.id, kind: client.kind, identity: client.identity, connectedAt: leaseStamps.next())
            let attachment = TerminalAttachment(
                sessionID: control.sessionID, clientID: client.id, mode: control.attachmentMode ?? .viewer, attachedAt: emittedAt)
            let payload = GhosttyRemoteSessionStatePayload(
                sessionID: control.sessionID, reason: TerminalRemoteSessionStateReason.attachmentState.rawValue, emittedAt: emittedAt,
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: control.sessionID, servicePID: 100, childPID: 200, state: .running, updatedAt: emittedAt),
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [attached], attachments: [attachment]), title: "terminal",
                workingDirectory: "/tmp/work", outputByteCount: 0)
            return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .terminalState(payload))
        }

        private static let leaseStamps = LeaseStampSequence()

        /// Hands out the distinct sub-second stamps a daemon's attach lease mints, in the format it mints
        /// them in. Shared across suites, so it is its own lock rather than a test's own state.
        private final class LeaseStampSequence: @unchecked Sendable {
            private let lock = NSLock()
            private var issued = 0

            func next() -> String {
                lock.lock()
                issued += 1
                let milliseconds = issued % 1000
                lock.unlock()
                return String(format: "2026-06-04T14:23:31.%03dZ", milliseconds)
            }
        }
    }
#endif
