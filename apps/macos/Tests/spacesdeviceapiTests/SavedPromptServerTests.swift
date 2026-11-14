#if canImport(Network) && canImport(Security)
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Device API coverage for the saved prompt library: each command answers with the whole ordered
    /// library and its revision, invalid and unknown input is refused, and the overview carries the
    /// revision clients use to decide when to fetch again.
    final class SavedPromptServerTests: XCTestCase {
        private let tlsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spaces-saved-prompt-tests-tls-\(UUID().uuidString)", isDirectory: true)

        /// Binds the profile to a throwaway database for this test, so the server's own store opens it and
        /// never a developer's profile.
        override func setUpWithError() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let keys = [SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
            let originals = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
            addTeardownBlock {
                for (name, value) in originals { if let value { setenv(name, value, 1) } else { unsetenv(name) } }
                try? FileManager.default.removeItem(at: root)
            }
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
        }

        override func tearDown() {
            try? FileManager.default.removeItem(at: tlsRoot)
            super.tearDown()
        }

        func testCreateUseUpdateAndDeleteAnswerWithTheOrderedLibrary() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let older = try harness.library(.createSavedPrompt(.init(title: "older", text: "one")))
            XCTAssertEqual(older.prompts.map(\.title), ["older"])
            let created = try harness.library(.createSavedPrompt(.init(title: "  newer  ", text: "two  ")))
            XCTAssertEqual(created.prompts.map(\.title), ["newer", "older"])
            XCTAssertEqual(created.prompts.first?.text, "two  ")
            XCTAssertGreaterThan(created.revision, older.revision)
            let olderID = try XCTUnwrap(created.prompts.last?.id)
            XCTAssertEqual(older.createdPromptID, older.prompts.first?.id)
            XCTAssertEqual(created.createdPromptID, created.prompts.first?.id, "a create names the row it inserted")

            let used = try harness.library(.recordSavedPromptUse(.init(id: olderID)))
            XCTAssertEqual(used.prompts.map(\.title), ["older", "newer"])
            XCTAssertNil(used.createdPromptID)

            let updated = try harness.library(.updateSavedPrompt(.init(id: olderID, title: "older edited", text: "changed")))
            XCTAssertEqual(updated.prompts.map(\.title), ["older edited", "newer"])
            XCTAssertEqual(updated.prompts.first?.text, "changed")
            XCTAssertNil(updated.createdPromptID)

            let listed = try harness.library(.listSavedPrompts)
            XCTAssertEqual(listed, updated)
            XCTAssertNil(listed.createdPromptID)

            let deleted = try harness.library(.deleteSavedPrompt(.init(id: olderID)))
            XCTAssertNil(deleted.createdPromptID)
            XCTAssertEqual(deleted.prompts.map(\.title), ["newer"])
            XCTAssertGreaterThan(deleted.revision, updated.revision)
        }

        func testBlankTitleOrTextIsRefused() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let blankTitle = try harness.send(.createSavedPrompt(.init(title: "  \n", text: "body")))
            XCTAssertFalse(blankTitle.ok)
            XCTAssertEqual(blankTitle.errorCode, .invalidArgument)
            let blankText = try harness.send(.createSavedPrompt(.init(title: "title", text: " \n ")))
            XCTAssertFalse(blankText.ok)
            XCTAssertEqual(blankText.errorCode, .invalidArgument)
            let created = try harness.library(.createSavedPrompt(.init(title: "title", text: "body")))
            let id = try XCTUnwrap(created.prompts.first?.id)
            let blankUpdate = try harness.send(.updateSavedPrompt(.init(id: id, title: "", text: "body")))
            XCTAssertEqual(blankUpdate.errorCode, .invalidArgument)

            let library = try harness.library(.listSavedPrompts)
            XCTAssertEqual(library.prompts.map(\.title), ["title"])
            XCTAssertEqual(library.revision, created.revision)
        }

        func testTextOverTheCapIsRefusedAndTextAtTheCapIsStored() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            let atCap = String(repeating: "a", count: SpacesDeviceSavedPrompt.maximumTextBytes)
            XCTAssertEqual(try harness.library(.createSavedPrompt(.init(title: "at cap", text: atCap))).prompts.count, 1)

            let overCap = try harness.send(.createSavedPrompt(.init(title: "over", text: atCap + "a")))
            XCTAssertFalse(overCap.ok)
            XCTAssertEqual(overCap.errorCode, .invalidArgument)
            XCTAssertEqual(overCap.message, "Prompts can be up to 100 KB.")
            // The cap counts UTF-8 bytes, not characters.
            let multibyte = String(repeating: "é", count: SpacesDeviceSavedPrompt.maximumTextBytes / 2 + 1)
            XCTAssertEqual(try harness.send(.createSavedPrompt(.init(title: "bytes", text: multibyte))).errorCode, .invalidArgument)
            XCTAssertEqual(try harness.library(.listSavedPrompts).prompts.count, 1)
        }

        func testAnUnknownPromptIsNotFound() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            for command in [
                SpacesDeviceAPICommand.updateSavedPrompt(.init(id: "missing", title: "t", text: "x")), .deleteSavedPrompt(.init(id: "missing")),
                .recordSavedPromptUse(.init(id: "missing")),
            ] {
                let response = try harness.send(command)
                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.errorCode, .notFound)
                XCTAssertEqual(response.message, "That prompt no longer exists.")
            }
        }

        func testTheOverviewCarriesTheRevisionOfTheLastAnswer() throws {
            let harness = try makeHarness()
            defer { harness.stop() }

            XCTAssertEqual(try harness.overviewRevision(), 0)
            let created = try harness.library(.createSavedPrompt(.init(title: "title", text: "body")))
            XCTAssertEqual(try harness.overviewRevision(), created.revision)
            let used = try harness.library(.recordSavedPromptUse(.init(id: try XCTUnwrap(created.prompts.first?.id))))
            XCTAssertEqual(try harness.overviewRevision(), used.revision)
        }

        private struct Harness {
            let server: SpacesDeviceAPIServer
            let client: SpacesDeviceAPIRequestSessionClient
            let clientApp: SpacesDeviceClientApp
            let token: String

            func stop() {
                client.cancel()
                server.stop()
            }

            func send(_ command: SpacesDeviceAPICommand) throws -> SpacesDeviceAPIResponse {
                try client.send(SpacesDeviceAPIRequest(command: command, authToken: token, clientApp: clientApp))
            }

            func library(_ command: SpacesDeviceAPICommand) throws -> SpacesDeviceSavedPromptsResult {
                let response = try send(command)
                XCTAssertTrue(response.ok, response.message)
                return try XCTUnwrap(response.savedPrompts)
            }

            func overviewRevision() throws -> Int {
                let response = try send(.overview)
                XCTAssertTrue(response.ok, response.message)
                return try XCTUnwrap(response.overview).savedPromptsRevision
            }
        }

        private func makeHarness() throws -> Harness {
            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: tlsRoot)
            let pairingStore = SavedPromptPairingStore()
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
            try server.start()
            let client = try SpacesDeviceAPIRequestSessionClient(
                resolver: SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint))
            let clientApp = SpacesDeviceClientApp(
                installationID: "saved-prompt-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                appVersion: "1.0")
            return Harness(server: server, client: client, clientApp: clientApp, token: pairingStore.authToken)
        }
    }

    private final class SavedPromptPairingStore: SpacesDevicePairingStoreProtocol {
        let authToken = "valid-token"

        func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
        func listDevices() throws -> [SpacesDevicePairedClient] { [] }
        func revoke(installationID _: String) throws {}
        func removeAll() throws {}
        func pushRegistrations() throws -> [String: SpacesDevicePushRegistration] { [:] }
        func setPushRegistration(_: SpacesDevicePushRegistration, forInstallationID _: String) throws {}
        func clearPushRegistration(forInstallationID _: String, matchingCapability _: String?) throws -> SpacesDevicePushRegistration? { nil }
        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
            guard clientApp != nil, authToken == self.authToken else {
                throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
            }
        }
        func validate(clientApp _: SpacesDeviceClientApp) throws {}
    }
#endif
