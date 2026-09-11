#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// What the app keeps a terminal's last screen for, and when it stops keeping it.
    ///
    /// The screens themselves are written and painted by `TerminalViewerModel` (see
    /// `TerminalViewerOpenPaintTests`); these are the two drops only the app model can make, because only
    /// it knows which sessions the device still lists and when the connection those sessions belong to
    /// has been left behind.
    @MainActor final class TerminalRetainedScreenStoreTests: XCTestCase {
        func testAnOverviewThatNoLongerListsASessionDropsItsRetainedScreen() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview(sessions: [
                Self.sessionSummary(id: "session-live"), Self.sessionSummary(id: "session-ended", state: .exited),
                Self.sessionSummary(id: "session-owned-elsewhere", ownedBy: "mac-owner"),
                Self.sessionSummary(id: "session-open", ownedBy: "phone-viewer"),
            ])
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            Self.retain(sessionID: "session-live", in: model.retainedTerminalScreens)
            Self.retain(sessionID: "session-gone", in: model.retainedTerminalScreens)
            Self.retain(sessionID: "session-ended", in: model.retainedTerminalScreens)
            Self.retain(sessionID: "session-owned-elsewhere", in: model.retainedTerminalScreens)
            Self.retain(sessionID: "session-open", in: model.retainedTerminalScreens)
            model.retainedTerminalScreens.noteOwnViewerClient(id: "phone-viewer")

            await model.refresh()

            XCTAssertEqual(
                model.retainedTerminalScreens.retainedSessionIDs, ["session-live", "session-open"],
                "unlisted, ended, and owned-elsewhere sessions lose their screens; a session owned by one of this app's own viewers keeps it")
        }

        /// The screens belong to the connection they were painted over: a session id from the previous
        /// device means nothing on the next one.
        func testAConnectionChangeDropsEveryRetainedScreen() {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            Self.retain(sessionID: "session-live", in: model.retainedTerminalScreens)

            model.handleAuthenticationFailure(message: "Pair this device again.")

            XCTAssertTrue(model.retainedTerminalScreens.retainedSessionIDs.isEmpty)
        }

        private static func retain(sessionID: String, in store: TerminalRetainedScreenStore) {
            store.retain(snapshot: snapshot(), epochID: "owner|1|2026-06-04T14:23:31Z|1|40x30", ownerEpoch: 1, forSessionID: sessionID)
        }

        private static func snapshot() -> GhosttyTerminalSnapshot {
            GhosttyTerminalSnapshot(
                columns: 40, rows: 30, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0,
                cells: Array(repeating: GhosttyTerminalSnapshot.Cell(codepoint: 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0), count: 1200)
            )
        }

        private static func sessionSummary(id: String, state: TerminalSessionState = .running, ownedBy ownerClientID: String? = nil)
            -> SpacesDeviceTerminalSessionSummary
        {
            let attachmentSnapshot =
                ownerClientID.map { clientID in
                    TerminalSessionAttachmentSnapshot(
                        clients: [
                            TerminalClient(
                                id: clientID, kind: .local, identity: TerminalClientIdentity(label: clientID), connectedAt: "2026-01-01T00:00:00Z")
                        ], attachments: [TerminalAttachment(sessionID: id, clientID: clientID, mode: .owner, attachedAt: "2026-01-01T00:00:00Z")])
                } ?? TerminalSessionAttachmentSnapshot()
            return SpacesDeviceTerminalSessionSummary(
                id: id, title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: state, backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-feature", workspaceTitle: nil, projectID: nil,
                projectName: nil, createdAt: "2026-06-04T14:23:10Z", updatedAt: "2026-06-04T14:23:23Z", isControlAvailable: true,
                isSubscriptionAvailable: true, attachmentSnapshot: attachmentSnapshot, rowKind: .process, rowSourceID: "process-row",
                hasFinalRender: false)
        }
    }
#endif
