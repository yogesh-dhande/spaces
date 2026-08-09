#if canImport(UIKit)
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// A program's OSC 52 copy inside a terminal session lands on the clipboard of the device the user is
    /// typing on. The daemon addresses each write to the client that owns the session and broadcasts it on
    /// the session's state stream, so every subscriber sees it and only the target applies it.
    @MainActor final class TerminalClipboardWriteTests: XCTestCase {
        private func settings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.port = 12345
            settings.authToken = "token"
            settings.certificateFingerprint = "SHA256:test"
            return settings
        }

        private func session() -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: "terminal-session", title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: .running,
                backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-07-28T00:00:00Z", updatedAt: "2026-07-28T00:00:01Z",
                isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), rowKind: .process,
                rowSourceID: "process-row", hasFinalRender: false)
        }

        /// An owner-interactive model plus a uniquely-named pasteboard, so no test touches the device's
        /// real clipboard. Returns the id the daemon would address a write for this session to.
        private func makeOwnerModel(_ pasteboard: UIPasteboard) async throws -> (model: TerminalViewerModel, ownerClientID: String) {
            let model = TerminalViewerModel(
                session: session(), settings: settings(), onAuthenticationRequired: { _ in }, onOpenTerminalDeepLink: { _ in })
            await model.configureOwnerInteractiveForTesting(ownerEpoch: 1)
            model.pasteboardOverrideForTesting = pasteboard
            let ownerClientID = try XCTUnwrap(model.latestState?.attachmentSnapshot?.attachments.first(where: { $0.mode == .owner })?.clientID)
            return (model, ownerClientID)
        }

        private func clipboardPayload(targetClientID: String, text: String) -> GhosttyRemoteSessionStatePayload {
            payload(reason: TerminalRemoteSessionStateReason.clipboardWrite, clipboardWrite: .init(targetClientID: targetClientID, text: text))
        }

        private func payload(reason: String, clipboardWrite: TerminalClipboardWritePayload? = nil) -> GhosttyRemoteSessionStatePayload {
            GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: reason, emittedAt: "2026-07-28T00:00:02Z", sessionStateRevision: nil, sessionStateFlags: nil,
                screenStateRevision: nil, runtimeState: nil, attachmentSnapshot: nil, title: "terminal", workingDirectory: "/tmp/work",
                outputByteCount: nil, clipboardWrite: clipboardWrite)
        }

        /// A clipboard write whose own snapshot disagrees with what this device currently holds: it names
        /// another device as the owner and carries a different title, standing in for an event that was
        /// emitted before a state refresh overtook it.
        private func staleSnapshotClipboardPayload(targetClientID: String, text: String) -> GhosttyRemoteSessionStatePayload {
            let otherClient = TerminalClient(
                id: "another-device", kind: .remoteViewer, identity: TerminalClientIdentity(label: "Another device"),
                connectedAt: "2026-07-28T00:00:00Z")
            return GhosttyRemoteSessionStatePayload(
                sessionID: "terminal-session", reason: TerminalRemoteSessionStateReason.clipboardWrite, emittedAt: "2026-07-28T00:00:02Z",
                sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: nil,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot(
                    clients: [otherClient],
                    attachments: [
                        TerminalAttachment(sessionID: "terminal-session", clientID: otherClient.id, mode: .owner, attachedAt: "2026-07-28T00:00:00Z")
                    ]), title: "regressed", workingDirectory: "/tmp/regressed", outputByteCount: nil,
                clipboardWrite: TerminalClipboardWritePayload(targetClientID: targetClientID, text: text))
        }

        private func withPasteboard(_ body: (UIPasteboard) async throws -> Void) async rethrows {
            let pasteboard = UIPasteboard.withUniqueName()
            defer { UIPasteboard.remove(withName: pasteboard.name) }
            try await body(pasteboard)
        }

        func testOwnerWritesTheCopiedTextToItsClipboard() async throws {
            try await withPasteboard { pasteboard in
                let (model, ownerClientID) = try await makeOwnerModel(pasteboard)

                await model.applyLatestState(clipboardPayload(targetClientID: ownerClientID, text: "copied text"), isOutOfBand: false)

                XCTAssertEqual(pasteboard.string, "copied text")
            }
        }

        /// A write addressed to another device is still delivered here — the state stream fans out — so
        /// the target check is what keeps a copy made on one device off every other device's clipboard.
        func testNonTargetClientLeavesItsClipboardAlone() async throws {
            try await withPasteboard { pasteboard in
                let (model, _) = try await makeOwnerModel(pasteboard)
                pasteboard.string = "what the user had"

                await model.applyLatestState(
                    clipboardPayload(targetClientID: "someone-elses-client", text: "not for this device"), isOutOfBand: false)

                XCTAssertEqual(pasteboard.string, "what the user had")
            }
        }

        /// A program that empties the terminal's clipboard travels as an empty write, which empties the
        /// owner's clipboard rather than leaving behind the content the program asked to remove.
        func testEmptyWriteClearsTheOwnersClipboard() async throws {
            try await withPasteboard { pasteboard in
                let (model, ownerClientID) = try await makeOwnerModel(pasteboard)
                pasteboard.string = "stale copy"

                await model.applyLatestState(clipboardPayload(targetClientID: ownerClientID, text: ""), isOutOfBand: false)

                XCTAssertNil(pasteboard.string)
            }
        }

        /// A clipboard write is an event, not state. The direct `.state` refresh runs alongside the live
        /// subscription, so an event emitted earlier can arrive after newer state has been installed —
        /// and installing what it carries would rewind the session to the moment the copy was made,
        /// handing ownership back to whoever held it then and blanking the viewer this device owns.
        /// Nothing it carries is applied, and the copy is judged against ownership as it stands now.
        func testClipboardWritePayloadDoesNotBecomeSessionState() async throws {
            try await withPasteboard { pasteboard in
                let (model, ownerClientID) = try await makeOwnerModel(pasteboard)
                let installedEmittedAt = model.latestState?.emittedAt
                let installedTitle = model.latestState?.title

                await model.applyLatestState(staleSnapshotClipboardPayload(targetClientID: ownerClientID, text: "copied text"), isOutOfBand: false)

                XCTAssertEqual(pasteboard.string, "copied text")
                XCTAssertTrue(model.isOwner, "an event's stale snapshot must not take ownership away from this device")
                XCTAssertEqual(model.latestState?.emittedAt, installedEmittedAt)
                XCTAssertEqual(model.latestState?.title, installedTitle)
            }
        }

        /// The write is a one-shot that rides exactly the payload announcing it. The client's stored state
        /// drops the field on merge, so the payloads that follow must not re-paste over whatever the user
        /// has copied since.
        func testALaterPayloadDoesNotRepeatTheWrite() async throws {
            try await withPasteboard { pasteboard in
                let (model, ownerClientID) = try await makeOwnerModel(pasteboard)
                await model.applyLatestState(clipboardPayload(targetClientID: ownerClientID, text: "copied once"), isOutOfBand: false)
                XCTAssertEqual(pasteboard.string, "copied once")

                pasteboard.string = "what the user copied next"
                await model.applyLatestState(payload(reason: TerminalRemoteSessionStateReason.output), isOutOfBand: false)

                XCTAssertEqual(pasteboard.string, "what the user copied next")
                // The second payload carries no attachment snapshot of its own, so this must come from
                // the reduction chain carrying the owner attachment forward, not from this payload
                // replacing it outright — the failure mode an unseeded chain produces silently, with
                // nothing above failing to point at it.
                XCTAssertTrue(model.isOwner, "a later frameless payload must not drop ownership the chain was seeded with")
            }
        }
    }
#endif
