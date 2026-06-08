import Foundation
import Network
import XCTest
import spacesmobilecore

@testable import spacesmobilebridge
@testable import spacesterminalcore
@testable import workspacecore

final class SpacesAppLauncherTests: XCTestCase {
    func testResolverReturnsDevelopmentSiblingExecutable() throws {
        let servicePath = "/tmp/spaces-build/debug/SpacesTerminalService"
        let expected = "/tmp/spaces-build/debug/SpacesApp"
        let resolver = SpacesAppExecutableResolver(isExecutableFile: { $0 == expected })

        let resolution = try resolver.resolve(serviceExecutablePath: servicePath)

        XCTAssertEqual(resolution.executableURL.path, expected)
        XCTAssertEqual(resolution.attemptedCandidates, [expected])
    }

    func testResolverReturnsBundledAppExecutable() throws {
        let servicePath = "/Applications/Spaces.app/Contents/Resources/SpacesTerminalService"
        let expected = "/Applications/Spaces.app/Contents/MacOS/SpacesApp"
        let resolver = SpacesAppExecutableResolver(isExecutableFile: { $0 == expected })

        let resolution = try resolver.resolve(serviceExecutablePath: servicePath)

        XCTAssertEqual(resolution.executableURL.path, expected)
        XCTAssertEqual(
            resolution.attemptedCandidates,
            ["/Applications/Spaces.app/Contents/Resources/SpacesApp", "/Applications/Spaces.app/Contents/MacOS/SpacesApp"])
    }

    func testResolverReturnsSystemInstallAppExecutable() throws {
        let expected = "/Applications/Spaces.app/Contents/MacOS/SpacesApp"
        let resolver = SpacesAppExecutableResolver(isExecutableFile: { $0 == expected })

        let resolution = try resolver.resolve(serviceExecutablePath: "/usr/local/bin/SpacesTerminalService")

        XCTAssertEqual(resolution.executableURL.path, expected)
        XCTAssertEqual(resolution.attemptedCandidates, ["/usr/local/bin/SpacesApp", "/Applications/Spaces.app/Contents/MacOS/SpacesApp"])
    }

    func testResolverReturnsUserInstallAppExecutable() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let expected = "/Users/tester/Applications/Spaces.app/Contents/MacOS/SpacesApp"
        let resolver = SpacesAppExecutableResolver(homeDirectoryURL: home, isExecutableFile: { $0 == expected })

        let resolution = try resolver.resolve(serviceExecutablePath: "/Users/tester/.local/bin/SpacesTerminalService")

        XCTAssertEqual(resolution.executableURL.path, expected)
        XCTAssertEqual(
            resolution.attemptedCandidates, ["/Users/tester/.local/bin/SpacesApp", "/Users/tester/Applications/Spaces.app/Contents/MacOS/SpacesApp"])
    }

    func testResolverReportsMissingAppWithAttemptedCandidates() throws {
        let resolver = SpacesAppExecutableResolver(isExecutableFile: { _ in false })

        XCTAssertThrowsError(try resolver.resolve(serviceExecutablePath: "/usr/local/bin/SpacesTerminalService")) { error in
            guard case SpacesAppLaunchError.executableNotFound(let candidates) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(candidates, ["/usr/local/bin/SpacesApp", "/Applications/Spaces.app/Contents/MacOS/SpacesApp"])
            XCTAssertTrue(error.localizedDescription.contains("/usr/local/bin/SpacesApp"))
            XCTAssertTrue(error.localizedDescription.contains("/Applications/Spaces.app/Contents/MacOS/SpacesApp"))
        }
    }

    func testLauncherReturnsAlreadyRunningWithoutSpawning() throws {
        let profile = makeProfile()
        let owner = makeOwner(profile: profile)
        var didStartProcess = false
        let launcher = SpacesAppLauncher(
            profileProvider: { profile }, currentAppOwner: { _ in owner },
            serviceExecutablePathProvider: {
                XCTFail("Service executable should not be resolved when app is running.")
                return nil
            },
            startProcess: { _, _ in
                didStartProcess = true
                return 100
            })

        let outcome = try launcher.launchIfNeeded()

        XCTAssertEqual(outcome.message, "Spaces is already running on Mac.")
        XCTAssertNil(outcome.launchedProcessID)
        XCTAssertFalse(didStartProcess)
    }

    func testLauncherStartsOncePassesProfileEnvironmentAndSucceedsWhenLeaseAppears() throws {
        let profile = makeProfile()
        let owner = makeOwner(profile: profile, pid: 456)
        let executablePath = "/tmp/build/SpacesApp"
        var ownerChecks = 0
        var didStartProcess = false
        var startedURL: URL?
        var startedEnvironment: [String: String]?
        let launcher = SpacesAppLauncher(
            resolver: SpacesAppExecutableResolver(isExecutableFile: { $0 == executablePath }), profileProvider: { profile },
            currentAppOwner: { _ in
                ownerChecks += 1
                return didStartProcess && ownerChecks >= 2 ? owner : nil
            }, serviceExecutablePathProvider: { "/tmp/build/SpacesTerminalService" },
            environmentProvider: { ["SPACES_DB_PATH": "/stale/spaces.db", "CUSTOM": "1"] },
            startProcess: { url, environment in
                didStartProcess = true
                startedURL = url
                startedEnvironment = environment
                return 123
            }, sleep: { _ in })

        let outcome = try launcher.launchIfNeeded(timeoutSeconds: 1, pollIntervalSeconds: 0.001)

        XCTAssertEqual(outcome.message, "Launched Spaces on Mac.")
        XCTAssertEqual(outcome.launchedProcessID, 123)
        XCTAssertEqual(startedURL?.path, executablePath)
        XCTAssertEqual(startedEnvironment?[SpacesProfile.databasePathEnvironmentVariable], profile.databasePath)
        XCTAssertEqual(startedEnvironment?[SpacesProfile.runtimeDirectoryEnvironmentVariable], profile.runtimeDirectory)
        XCTAssertEqual(startedEnvironment?["SPACES_TERMINAL_SERVICE_EXECUTABLE"], "/tmp/build/SpacesTerminalService")
        XCTAssertEqual(startedEnvironment?["CUSTOM"], "1")
    }

    func testLauncherFailsClearlyWhenLeaseDoesNotAppear() throws {
        let profile = makeProfile()
        var startCount = 0
        let launcher = SpacesAppLauncher(
            resolver: SpacesAppExecutableResolver(isExecutableFile: { $0 == "/tmp/build/SpacesApp" }), profileProvider: { profile },
            currentAppOwner: { _ in nil }, serviceExecutablePathProvider: { "/tmp/build/SpacesTerminalService" },
            startProcess: { _, _ in
                startCount += 1
                return 123
            }, sleep: { _ in })

        XCTAssertThrowsError(try launcher.launchIfNeeded(timeoutSeconds: 0.001, pollIntervalSeconds: 0.001)) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not acquire the profile app-owner lease"))
            XCTAssertTrue(error.localizedDescription.contains("/tmp/build/SpacesApp"))
        }
        XCTAssertEqual(startCount, 1)
    }

    func testBridgeLaunchCommandRejectsUnauthenticatedRequests() throws {
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let store = StubMobilePairingStore()
        var launchCount = 0
        let server = SpacesMobileBridgeServer(
            host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: store,
            launchSpacesAppHandler: {
                launchCount += 1
                return SpacesAppLaunchOutcome(message: "Launched Spaces on Mac.", launchedProcessID: 1)
            })
        try server.start()
        defer { server.stop() }

        let response = try sendTLSRequest(
            SpacesMobileBridgeRequest(command: "launchSpacesApp", clientApp: Self.clientApp), port: server.listeningPort, transportKey: transportKey)

        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.message.contains("Invalid mobile auth token."))
        XCTAssertEqual(launchCount, 0)
    }

    func testBridgeLaunchCommandRejectsWhenLauncherIsNotInstalled() throws {
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let server = SpacesMobileBridgeServer(host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: StubMobilePairingStore())
        try server.start()
        defer { server.stop() }

        let response = try sendTLSRequest(
            SpacesMobileBridgeRequest(command: "launchSpacesApp", authToken: StubMobilePairingStore.validToken, clientApp: Self.clientApp),
            port: server.listeningPort, transportKey: transportKey)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.message, "launchSpacesApp is only available from the daemon-hosted mobile bridge.")
    }

    func testBridgeLaunchCommandReturnsAlreadyRunningAndLaunchedOutcomes() throws {
        let alreadyRunning = try sendLaunchCommandResponse(
            outcome: SpacesAppLaunchOutcome(message: "Spaces is already running on Mac.", launchedProcessID: nil))
        let launched = try sendLaunchCommandResponse(outcome: SpacesAppLaunchOutcome(message: "Launched Spaces on Mac.", launchedProcessID: 42))

        XCTAssertTrue(alreadyRunning.ok)
        XCTAssertEqual(alreadyRunning.message, "Spaces is already running on Mac.")
        XCTAssertTrue(launched.ok)
        XCTAssertEqual(launched.message, "Launched Spaces on Mac.")
    }

    private func sendLaunchCommandResponse(outcome: SpacesAppLaunchOutcome) throws -> SpacesMobileBridgeResponse {
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let server = SpacesMobileBridgeServer(
            host: "127.0.0.1", port: 0, transportKey: transportKey, pairingStoreProtocol: StubMobilePairingStore(),
            launchSpacesAppHandler: { outcome })
        try server.start()
        defer { server.stop() }

        return try sendTLSRequest(
            SpacesMobileBridgeRequest(command: "launchSpacesApp", authToken: StubMobilePairingStore.validToken, clientApp: Self.clientApp),
            port: server.listeningPort, transportKey: transportKey)
    }

    private static let clientApp = SpacesMobileClientApp(
        installationID: "INSTALLATION-1", bundleID: SpacesMobileFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
        appVersion: "1.0")

    private func makeProfile() -> SpacesProfile {
        SpacesProfile(
            source: .explicitDatabasePath, databasePath: "/tmp/profile/spaces.db", rootDirectory: "/tmp/profile",
            runtimeDirectory: "/tmp/profile/runtime", ipcNotificationObject: "spaces.profile.test", developmentContext: nil, branchSlug: nil,
            worktreeHash: nil)
    }

    private func makeOwner(profile: SpacesProfile, pid: Int32 = 123) -> SpacesProcessLeaseOwner {
        SpacesProcessLeaseOwner(
            pid: pid, executablePath: "/tmp/build/SpacesApp", profileRoot: profile.rootDirectory, token: "owner-token-\(pid)",
            acquiredAt: "2026-06-01T00:00:00Z")
    }

    private func sendTLSRequest(_ request: SpacesMobileBridgeRequest, port: Int, transportKey: String) throws -> SpacesMobileBridgeResponse {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.app.launcher.bridge.test")
        let resultBox = BridgeRequestResultBox()
        let connection = NWConnection(
            host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: try SpacesMobileBridgeTransport.parameters(transportKey: transportKey, role: .client))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                resultBox.setError(error)
                ready.signal()
                sent.signal()
                received.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        if let error = resultBox.error() { throw error }

        var requestData = try SpacesMobileBridgeCodec.encodeRequest(request)
        requestData.append(0x0A)
        connection.send(
            content: requestData,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        XCTAssertEqual(sent.wait(timeout: .now() + 5), .success)
        if let error = resultBox.error() { throw error }

        @Sendable func receiveNext(_ data: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resultBox.setError(error)
                    received.signal()
                    return
                }
                var nextData = data
                if let content { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    resultBox.setResponseData(Data(nextData.prefix(upTo: newlineIndex)))
                    received.signal()
                    return
                }
                if isComplete {
                    resultBox.setResponseData(nextData)
                    received.signal()
                    return
                }
                receiveNext(nextData)
            }
        }
        receiveNext(Data())
        XCTAssertEqual(received.wait(timeout: .now() + 5), .success)
        connection.cancel()
        if let error = resultBox.error() { throw error }
        return try SpacesMobileBridgeCodec.decodeResponse(resultBox.responseData())
    }
}

private final class StubMobilePairingStore: SpacesMobilePairingStoreProtocol {
    static let validToken = "valid-token"

    func issueToken(for _: SpacesMobileClientApp) throws -> String { Self.validToken }
    func listDevices() throws -> [SpacesMobilePairedDevice] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}

    func authorize(clientApp: SpacesMobileClientApp?, authToken: String?) throws {
        guard clientApp != nil, authToken == Self.validToken else {
            throw NSError(domain: "SpacesMobileBridgeServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid mobile auth token."])
        }
    }

    func validate(clientApp _: SpacesMobileClientApp) throws {}
}

private final class BridgeRequestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedResponseData = Data()

    func setError(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }

    func error() -> Error? {
        lock.lock()
        let error = storedError
        lock.unlock()
        return error
    }

    func setResponseData(_ data: Data) {
        lock.lock()
        storedResponseData = data
        lock.unlock()
    }

    func responseData() -> Data {
        lock.lock()
        let data = storedResponseData
        lock.unlock()
        return data
    }
}
