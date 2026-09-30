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

        /// A screen survives only as long as some overview still lists its session as retainable
        /// (`pruneRetainedTerminalScreens` unions the published `overview` with every paired device's own
        /// `overview(forDeviceID:)`). With no paired device and no published overview, nothing can vouch
        /// for the session, so an auth failure that clears the selected device's own overview drops it.
        func testARetainedScreenWithNoPairedDeviceBehindItDrops() {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            Self.retain(sessionID: "session-live", in: model.retainedTerminalScreens)

            model.handleAuthenticationFailure(message: "Pair this device again.")

            XCTAssertTrue(model.retainedTerminalScreens.retainedSessionIDs.isEmpty)
        }

        /// A non-selected device's retained screen must survive a switch between two other devices:
        /// `pruneRetainedTerminalScreens` unions every paired device's own `deviceOverviews` entry, not
        /// just the newly selected device's, so switching from A to C and back never touches B's screen.
        /// Unpairing B is what actually drops it, once `removeDevice` clears its `deviceOverviews` entry
        /// (see that method's own doc comment on why it does this unconditionally, not only through the
        /// stream-gated reconcile pass).
        func testRetainedScreenForANonSelectedDeviceSurvivesADeviceSwitchButDropsOnUnpair() throws {
            let fingerprintA = "fp-device-a-retainswitch"
            let fingerprintB = "fp-device-b-retainswitch"
            let fingerprintC = "fp-device-c-retainswitch"
            var settingsA = SpacesMobileConnectionSettings()
            settingsA.certificateFingerprint = fingerprintA
            settingsA.authToken = "token-a-retainswitch"
            var settingsB = SpacesMobileConnectionSettings()
            settingsB.certificateFingerprint = fingerprintB
            settingsB.authToken = "token-b-retainswitch"
            var settingsC = SpacesMobileConnectionSettings()
            settingsC.certificateFingerprint = fingerprintC
            settingsC.authToken = "token-c-retainswitch"
            let deviceA = try XCTUnwrap(
                SpacesMobileDeviceStore.upsert(settings: settingsA, name: "device-a-retainswitch").devices.first(where: {
                    $0.certificateFingerprint == fingerprintA
                }))
            let deviceB = try XCTUnwrap(
                SpacesMobileDeviceStore.upsert(settings: settingsB, name: "device-b-retainswitch").devices.first(where: {
                    $0.certificateFingerprint == fingerprintB
                }))
            let deviceC = try XCTUnwrap(
                SpacesMobileDeviceStore.upsert(settings: settingsC, name: "device-c-retainswitch").devices.first(where: {
                    $0.certificateFingerprint == fingerprintC
                }))
            defer {
                for device in [deviceA, deviceB, deviceC] {
                    _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
                }
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }

            let client = SpacesDeviceAPIClient(settings: settingsA) { _ in
                XCTFail("This test drives only device switches and an unpair, never a request.")
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = SpacesMobileAppModel(settings: settingsA, bridgeClient: client)
            model.activeDeviceID = deviceA.id
            model.pairedDevices = [deviceA, deviceB, deviceC]
            model.setDeviceOverviewForTesting(makeOverview(sessions: [Self.sessionSummary(id: "session-b")]), deviceID: deviceB.id)
            Self.retain(sessionID: "session-b", in: model.retainedTerminalScreens)

            model.selectDevice(id: deviceC.id)
            XCTAssertTrue(
                model.retainedTerminalScreens.retainedSessionIDs.contains("session-b"),
                "switching to another device must not drop a third device's retained screen")

            model.selectDevice(id: deviceA.id)
            XCTAssertTrue(
                model.retainedTerminalScreens.retainedSessionIDs.contains("session-b"),
                "switching back must still leave the third device's screen alone")

            model.removeDevice(id: deviceB.id)
            XCTAssertFalse(
                model.retainedTerminalScreens.retainedSessionIDs.contains("session-b"), "unpairing the device that owned the screen must drop it")
        }

        /// The previously *selected* device's own retained screen must also survive switching away from
        /// it. `selectDevice` calls `clearActiveDeviceFacts()` (which nils `overview` and prunes) before
        /// moving `activeDeviceID` to the new device, so at prune time `overview` already reads nil while
        /// `activeDeviceID` still names device A: reading every device through `overview(forDeviceID:)`
        /// (rather than splitting between the nilled `overview` field and a `deviceID != activeDeviceID`-
        /// guarded loop over `deviceOverviews`, which would skip A on both counts at that exact instant)
        /// is what still finds A's own cached overview and keeps its screen.
        func testASelectedDevicesOwnRetainedScreenSurvivesSwitchingAwayButDropsOnUnpair() throws {
            let fingerprintA = "fp-device-a-selfretain"
            let fingerprintB = "fp-device-b-selfretain"
            var settingsA = SpacesMobileConnectionSettings()
            settingsA.certificateFingerprint = fingerprintA
            settingsA.authToken = "token-a-selfretain"
            var settingsB = SpacesMobileConnectionSettings()
            settingsB.certificateFingerprint = fingerprintB
            settingsB.authToken = "token-b-selfretain"
            let deviceA = try XCTUnwrap(
                SpacesMobileDeviceStore.upsert(settings: settingsA, name: "device-a-selfretain").devices.first(where: {
                    $0.certificateFingerprint == fingerprintA
                }))
            let deviceB = try XCTUnwrap(
                SpacesMobileDeviceStore.upsert(settings: settingsB, name: "device-b-selfretain").devices.first(where: {
                    $0.certificateFingerprint == fingerprintB
                }))
            defer {
                for device in [deviceA, deviceB] {
                    _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
                }
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.paired-devices")
                UserDefaults.standard.removeObject(forKey: "spaces.mobile.active-device-id")
            }

            let client = SpacesDeviceAPIClient(settings: settingsA) { _ in
                XCTFail("This test drives only a device switch and an unpair, never a request.")
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = SpacesMobileAppModel(settings: settingsA, bridgeClient: client)
            model.activeDeviceID = deviceA.id
            model.pairedDevices = [deviceA, deviceB]
            model.setDeviceOverviewForTesting(makeOverview(sessions: [Self.sessionSummary(id: "session-a")]), deviceID: deviceA.id)
            Self.retain(sessionID: "session-a", in: model.retainedTerminalScreens)

            model.selectDevice(id: deviceB.id)
            XCTAssertTrue(
                model.retainedTerminalScreens.retainedSessionIDs.contains("session-a"),
                "switching away from device A must not drop its own retained screen")

            model.removeDevice(id: deviceA.id)
            XCTAssertFalse(
                model.retainedTerminalScreens.retainedSessionIDs.contains("session-a"), "unpairing the device that owned the screen must drop it")
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
