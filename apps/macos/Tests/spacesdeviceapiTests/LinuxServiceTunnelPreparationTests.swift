#if os(Linux) && canImport(OpenSSL)
    import Foundation
    import XCTest

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    final class LinuxServiceTunnelPreparationTests: XCTestCase {
        func testAuthorizationFailureReturnsUnauthorizedRejection() throws {
            let identityRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "spaces-linux-tunnel-preparation-tests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: identityRoot) }
            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: identityRoot)
            let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: RejectingPairingStore())
            let tunnelRequest = SpacesDeviceServiceTunnelRequest(workspaceID: "workspace-1", serviceName: "web")
            let request = SpacesDeviceAPIRequest(
                command: .openServiceTunnel(tunnelRequest), authToken: "revoked-token",
                clientApp: SpacesDeviceClientApp(
                    installationID: "revoked-installation", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                    deviceName: "iPhone", appVersion: "1.0"))

            let outcome = server.prepareServiceTunnel(request, tunnelRequest: tunnelRequest)

            guard case .reject(let response) = outcome else {
                XCTFail("Authorization failures must return a protocol rejection instead of escaping the tunnel branch.")
                return
            }
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.errorCode, .unauthorized)
            XCTAssertEqual(response.message, SpacesDevicePairingError.invalidAuthToken.localizedDescription)
        }
    }

    private final class RejectingPairingStore: SpacesDevicePairingStoreProtocol, @unchecked Sendable {
        func issueToken(for clientApp: SpacesDeviceClientApp, presentedToken: String?) throws -> String {
            throw SpacesDevicePairingError.invalidAuthToken
        }

        func listDevices() throws -> [SpacesDevicePairedClient] { [] }

        func revoke(installationID: String) throws {}

        func removeAll() throws {}

        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws { throw SpacesDevicePairingError.invalidAuthToken }

        func validate(clientApp: SpacesDeviceClientApp) throws {}
    }
#endif
