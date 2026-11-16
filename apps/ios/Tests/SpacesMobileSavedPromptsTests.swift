#if canImport(UIKit)
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// A stand-in for a device's daemon that keeps prompts in memory, orders them and raises its revision
    /// the way the real one does, and records the commands it receives.
    final class FakePromptDevice: @unchecked Sendable {
        enum Command: Equatable {
            case list
            case create(title: String)
            case update(id: String)
            case delete(id: String)
            case use(id: String)
        }

        private let lock = NSLock()
        private var prompts: [SpacesDeviceSavedPrompt]
        private var revision: Int
        private var recorded: [Command] = []
        private var counter = 0
        private var replacementAfterList: [SpacesDeviceSavedPrompt]?

        init(prompts: [SpacesDeviceSavedPrompt] = [], revision: Int = 1) {
            self.prompts = prompts
            self.revision = revision
        }

        var commands: [Command] { lock.withLock { recorded } }
        var currentRevision: Int { lock.withLock { revision } }

        /// Replaces the device's prompts as if another client had changed them.
        func replacePrompts(_ prompts: [SpacesDeviceSavedPrompt]) {
            lock.withLock {
                self.prompts = prompts
                revision += 1
            }
        }

        /// Another client changes the prompts right after the next list request has been answered, so that
        /// answer is already stale when it arrives.
        func replacePromptsAfterNextList(_ prompts: [SpacesDeviceSavedPrompt]) { lock.withLock { replacementAfterList = prompts } }

        func overview(revision: Int? = nil) -> SpacesDeviceOverviewPayload {
            SpacesDeviceOverviewPayload(
                workspaces: [], sessions: [],
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version), savedPromptsRevision: revision ?? currentRevision)
        }

        func client(settings: SpacesMobileConnectionSettings = SpacesMobileConnectionSettings()) -> SpacesDeviceAPIClient {
            SpacesDeviceAPIClient(settings: settings) { [self] request in respond(to: request) }
        }

        private func respond(to request: SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse {
            lock.withLock {
                switch request.command {
                case .listSavedPrompts: recorded.append(.list)
                case .createSavedPrompt(let fields):
                    recorded.append(.create(title: fields.title))
                    if fields.text.utf8.count > SpacesDeviceSavedPrompt.maximumTextBytes {
                        return SpacesDeviceAPIResponse(ok: false, message: SpacesDeviceSavedPrompt.tooLongMessage, errorCode: .invalidArgument)
                    }
                    counter += 1
                    let stamp = Self.stamp(offset: 1_000 + counter)
                    prompts.append(
                        SpacesDeviceSavedPrompt(
                            id: "new-\(counter)", title: fields.title, text: fields.text, createdAt: stamp, updatedAt: stamp, lastUsedAt: stamp))
                    revision += 1
                case .updateSavedPrompt(let update):
                    recorded.append(.update(id: update.id))
                    guard let index = prompts.firstIndex(where: { $0.id == update.id }) else { return Self.missing() }
                    let old = prompts[index]
                    prompts[index] = SpacesDeviceSavedPrompt(
                        id: old.id, title: update.title, text: update.text, createdAt: old.createdAt, updatedAt: old.updatedAt,
                        lastUsedAt: old.lastUsedAt)
                    revision += 1
                case .deleteSavedPrompt(let reference):
                    recorded.append(.delete(id: reference.id))
                    guard prompts.contains(where: { $0.id == reference.id }) else { return Self.missing() }
                    prompts.removeAll { $0.id == reference.id }
                    revision += 1
                case .recordSavedPromptUse(let reference):
                    recorded.append(.use(id: reference.id))
                    guard let index = prompts.firstIndex(where: { $0.id == reference.id }) else { return Self.missing() }
                    let old = prompts[index]
                    counter += 1
                    prompts[index] = SpacesDeviceSavedPrompt(
                        id: old.id, title: old.title, text: old.text, createdAt: old.createdAt, updatedAt: old.updatedAt,
                        lastUsedAt: Self.stamp(offset: 1_000 + counter))
                    revision += 1
                default: break
                }
                let ordered = prompts.sorted { ($0.lastUsedAt, $0.id) > ($1.lastUsedAt, $1.id) }
                let response = SpacesDeviceAPIResponse(
                    ok: true, message: "ok", result: .savedPrompts(SpacesDeviceSavedPromptsResult(prompts: ordered, revision: revision)))
                if case .listSavedPrompts = request.command, let replacement = replacementAfterList {
                    prompts = replacement
                    revision += 1
                    replacementAfterList = nil
                }
                return response
            }
        }

        private static func missing() -> SpacesDeviceAPIResponse {
            SpacesDeviceAPIResponse(ok: false, message: "That prompt no longer exists.", errorCode: .notFound)
        }

        static func stamp(offset: Int) -> String {
            TerminalSessionTimestamp.fractionalString(from: Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(offset)))
        }

        static func prompt(_ id: String, title: String, text: String = "Body", used: Int) -> SpacesDeviceSavedPrompt {
            let stamp = stamp(offset: used)
            return SpacesDeviceSavedPrompt(id: id, title: title, text: text, createdAt: stamp, updatedAt: stamp, lastUsedAt: stamp)
        }
    }

    extension SpacesDeviceSavedPrompt {
        static func prompt(_ id: String, title: String, text: String = "Body", used: Int) -> SpacesDeviceSavedPrompt {
            FakePromptDevice.prompt(id, title: title, text: text, used: used)
        }
    }

    @MainActor final class SpacesMobileSavedPromptsTests: XCTestCase {
        private func record(_ id: String) -> SpacesMobilePairedDeviceRecord {
            SpacesMobilePairedDeviceRecord(
                id: id, name: "Device \(id)", hosts: ["127.0.0.1"], port: 47_847, certificateFingerprint: "fp-\(id)",
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
        }

        /// Device `a` is selected; each extra device is a non-selected paired device with its own client.
        private func makeModel(a: FakePromptDevice, others: [(String, FakePromptDevice)] = []) -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: a.client(settings: settings))
            model.savedPrompts.pasteboard = UIPasteboard.withUniqueName()
            model.pairedDevices = [record("a")] + others.map { record($0.0) }
            model.activeDeviceID = "a"
            for (id, device) in others {
                let deviceSettings = SpacesMobileDeviceStore.settings(from: record(id), installationID: settings.installationID)
                model.setNonActiveDeviceStreamClientForTesting(device.client(settings: deviceSettings), settings: deviceSettings, deviceID: id)
                model.setDeviceOverviewForTesting(device.overview(), deviceID: id)
            }
            model.overview = a.overview()
            return model
        }

        private func eventually(_ message: String, _ condition: @MainActor () -> Bool) async {
            for _ in 0..<200 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTFail(message)
        }

        private func titles(_ model: SpacesMobileAppModel, query: String = "") -> [String] {
            model.savedPrompts.entries(matching: query).map(\.prompt.title)
        }

        func testMergedListOrdersAcrossDevicesMostRecentlyUsedFirst() async {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A old", used: 1), .prompt("a2", title: "A new", used: 30)])
            let b = FakePromptDevice(prompts: [.prompt("b1", title: "B mid", used: 20)])
            let model = makeModel(a: a, others: [("b", b)])

            await eventually("both devices' prompts load") { self.titles(model).count == 3 }

            XCTAssertEqual(titles(model), ["A new", "B mid", "A old"])
            XCTAssertTrue(model.savedPrompts.showsDeviceNames)
        }

        func testAnOfflineDevicesPromptsAreHiddenAndReturnWhenItComesBack() async {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", used: 1)])
            let b = FakePromptDevice(prompts: [.prompt("b1", title: "B", used: 2)])
            let model = makeModel(a: a, others: [("b", b)])
            await eventually("loads") { self.titles(model).count == 2 }

            model.setOfflineForTesting(true, deviceID: "b")
            XCTAssertEqual(titles(model), ["A"])

            model.setOfflineForTesting(false, deviceID: "b")
            await eventually("B returns") { self.titles(model) == ["B", "A"] }
        }

        func testARevisionBumpInAnOverviewRefetchesThatDevice() async {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "Before", used: 1)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model) == ["Before"] }

            a.replacePrompts([.prompt("a1", title: "After", used: 1)])
            model.overview = a.overview()

            await eventually("refetch lands") { self.titles(model) == ["After"] }
        }

        func testAnUnchangedRevisionDoesNotRefetch() async {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "Same", used: 1)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model) == ["Same"] }

            model.overview = a.overview()
            model.overview = a.overview()
            try? await Task.sleep(for: .milliseconds(100))

            XCTAssertEqual(a.commands, [.list])
        }

        func testARevisionAnnouncedWhileAFetchIsInFlightIsFetchedWhenThatFetchLands() async {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "Before", used: 1)])
            a.replacePromptsAfterNextList([.prompt("a1", title: "After", used: 1)])
            let model = makeModel(a: a)
            model.overview = a.overview(revision: 2)

            await eventually("the second revision is fetched") { self.titles(model) == ["After"] }
        }

        func testCopyWritesThePasteboardAndRecordsTheUseOnTheOwningDevice() async throws {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", used: 1)])
            let b = FakePromptDevice(prompts: [.prompt("b1", title: "B", text: "Hello from B", used: 2), .prompt("b2", title: "B2", used: 1)])
            let model = makeModel(a: a, others: [("b", b)])
            await eventually("loads") { self.titles(model).count == 3 }
            let entry = try XCTUnwrap(model.savedPrompts.entries(matching: "B2").first)

            await model.savedPrompts.copy(deviceID: entry.deviceID, promptID: entry.prompt.id, text: "Hello from B").value

            XCTAssertEqual(model.savedPrompts.pasteboard.string, "Hello from B")
            XCTAssertEqual(b.commands.last, .use(id: "b2"))
            XCTAssertFalse(a.commands.contains(.use(id: "b2")))
            XCTAssertEqual(titles(model).first, "B2", "the copied prompt moves to the top of the merged list")
        }

        func testCopyingEditedTextCopiesTheDraftWithoutSavingIt() async throws {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", text: "Original", used: 1)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model) == ["A"] }
            model.savedPrompts.beginEditing(try XCTUnwrap(model.savedPrompts.entries(matching: "").first))
            model.savedPrompts.draft?.text = "Edited"
            let draft = try XCTUnwrap(model.savedPrompts.draft)

            await model.savedPrompts.copy(deviceID: draft.deviceID, promptID: draft.promptID, text: draft.text).value

            XCTAssertEqual(model.savedPrompts.pasteboard.string, "Edited")
            XCTAssertEqual(a.commands.last, .use(id: "a1"))
            XCTAssertFalse(a.commands.contains(.update(id: "a1")))
            XCTAssertTrue(model.savedPrompts.isDraftDirty, "copying does not save")
        }

        func testANewPromptIsCreatedOnTheChosenDevice() async {
            let a = FakePromptDevice()
            let b = FakePromptDevice()
            let model = makeModel(a: a, others: [("b", b)])
            await eventually("devices reachable and listed") {
                model.savedPrompts.reachableDevices.count == 2 && a.commands == [.list] && b.commands == [.list]
            }

            XCTAssertTrue(model.savedPrompts.beginNewPrompt())
            XCTAssertEqual(model.savedPrompts.draft?.deviceID, "a", "defaults to the selected device")
            model.savedPrompts.draft?.deviceID = "b"
            model.savedPrompts.draft?.title = "Fresh"
            model.savedPrompts.draft?.text = "Text"
            let outcome = await model.savedPrompts.saveDraft()

            XCTAssertEqual(outcome, .created)
            XCTAssertEqual(b.commands.last, .create(title: "Fresh"))
            XCTAssertFalse(a.commands.contains(.create(title: "Fresh")))
            XCTAssertEqual(titles(model), ["Fresh"])
        }

        func testSavingAnEditKeepsTheDraftCleanAndDiscardRestoresTheSavedText() async throws {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", text: "One", used: 1)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model) == ["A"] }
            model.savedPrompts.beginEditing(try XCTUnwrap(model.savedPrompts.entries(matching: "").first))

            model.savedPrompts.draft?.text = "Two"
            XCTAssertTrue(model.savedPrompts.isDraftDirty)
            model.savedPrompts.discardEdits()
            XCTAssertEqual(model.savedPrompts.draft?.text, "One")
            XCTAssertFalse(model.savedPrompts.isDraftDirty)

            model.savedPrompts.draft?.text = "Three"
            let outcome = await model.savedPrompts.saveDraft()
            XCTAssertEqual(outcome, .updated)
            XCTAssertFalse(model.savedPrompts.isDraftDirty)
            XCTAssertEqual(model.savedPrompts.entries(matching: "").first?.prompt.text, "Three")
        }

        func testTheDevicesMessageIsShownWhenSavingFails() async {
            let a = FakePromptDevice()
            let model = makeModel(a: a)
            await eventually("device reachable") { !model.savedPrompts.reachableDevices.isEmpty }
            model.savedPrompts.beginNewPrompt()
            model.savedPrompts.draft?.title = "Big"
            model.savedPrompts.draft?.text = String(repeating: "x", count: SpacesDeviceSavedPrompt.maximumTextBytes + 1)

            let outcome = await model.savedPrompts.saveDraft()

            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(model.savedPrompts.draft?.errorMessage, SpacesDeviceSavedPrompt.tooLongMessage)
            XCTAssertTrue(model.savedPrompts.isDraftDirty, "the edit is kept so the user can shorten it")
        }

        func testDeleteRemovesThePromptFromItsDevice() async throws {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", used: 1), .prompt("a2", title: "B", used: 2)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model).count == 2 }
            model.savedPrompts.beginEditing(try XCTUnwrap(model.savedPrompts.entries(matching: "A").first))

            let deleted = await model.savedPrompts.deleteDraft()

            XCTAssertTrue(deleted)
            XCTAssertEqual(a.commands.last, .delete(id: "a1"))
            XCTAssertEqual(titles(model), ["B"])
        }

        func testTextTypedWhileACreateWasInFlightIsKeptAsAnEditOfTheCreatedPrompt() async throws {
            let a = FakePromptDevice()
            let model = makeModel(a: a)
            await eventually("device reachable") { !model.savedPrompts.reachableDevices.isEmpty }
            model.savedPrompts.beginNewPrompt()
            model.savedPrompts.draft?.title = "Fresh"
            model.savedPrompts.draft?.text = "Text"
            let sent = try XCTUnwrap(model.savedPrompts.draft)
            model.savedPrompts.draft?.text = "Text and more"
            let created = FakePromptDevice.prompt("new-1", title: "Fresh", text: "Text", used: 5)

            let outcome = model.savedPrompts.finishSave(
                SpacesDeviceSavedPromptsResult(prompts: [created], revision: 2, createdPromptID: "new-1"), sent: sent)

            XCTAssertEqual(outcome, .updated, "the detail screen stays open")
            XCTAssertEqual(model.savedPrompts.draft?.promptID, "new-1")
            XCTAssertEqual(model.savedPrompts.draft?.text, "Text and more")
            XCTAssertTrue(model.savedPrompts.isDraftDirty)
        }

        func testADeleteResultDoesNotCloseAReplacementDraft() async throws {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", used: 1), .prompt("a2", title: "B", used: 2)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model).count == 2 }
            model.savedPrompts.beginEditing(try XCTUnwrap(model.savedPrompts.entries(matching: "A").first))
            let deleting = try XCTUnwrap(model.savedPrompts.draft)
            model.savedPrompts.beginEditing(try XCTUnwrap(model.savedPrompts.entries(matching: "B").first))
            model.savedPrompts.draft?.text = "typed in B"

            let closes = model.savedPrompts.finishDelete(SpacesDeviceSavedPromptsResult(prompts: [], revision: 2), deleted: deleting)

            XCTAssertFalse(closes)
            XCTAssertEqual(model.savedPrompts.draft?.promptID, "a2")
            XCTAssertEqual(model.savedPrompts.draft?.text, "typed in B")
        }

        func testACleanDraftFollowsRemoteEditsAndADirtyOneIsKept() async throws {
            let a = FakePromptDevice(prompts: [.prompt("a1", title: "A", text: "One", used: 1)])
            let model = makeModel(a: a)
            await eventually("loads") { self.titles(model) == ["A"] }
            model.savedPrompts.beginEditing(try XCTUnwrap(model.savedPrompts.entries(matching: "").first))

            a.replacePrompts([.prompt("a1", title: "A", text: "Remote", used: 1)])
            model.overview = a.overview()
            await eventually("clean draft follows") { model.savedPrompts.draft?.text == "Remote" }

            model.savedPrompts.draft?.text = "Mine"
            a.replacePrompts([.prompt("a1", title: "A", text: "Remote again", used: 1)])
            model.overview = a.overview()
            await eventually("library updates") { model.savedPrompts.entries(matching: "").first?.prompt.text == "Remote again" }
            XCTAssertEqual(model.savedPrompts.draft?.text, "Mine")
        }

        func testRowCaptionNamesTheDeviceOnlyWhenAskedAndShowsTheAge() {
            let prompt = FakePromptDevice.prompt("p", title: "T", used: 0)
            let entry = SavedPromptLibrary.Entry(deviceID: "d", deviceName: "Mac mini", prompt: prompt)
            let now = Date(timeIntervalSince1970: 1_800_000_000 + 2 * 3600)

            XCTAssertEqual(SavedPromptRowCaption.text(for: entry, showsDeviceName: true, relativeTo: now), "Mac mini \u{00B7} 2h")
            XCTAssertEqual(SavedPromptRowCaption.text(for: entry, showsDeviceName: false, relativeTo: now), "2h")
        }
    }
#endif
