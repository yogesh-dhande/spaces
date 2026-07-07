import Darwin
import Foundation
import Network
import XCTest
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacesdeviceapi

private let supervisorTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "spaces-device-api-supervisor-tests-tls-\(UUID().uuidString)", isDirectory: true)

/// One pinned-TLS identity per test process: generation is expensive and every server/client pair
/// only needs a stable certificate to pin.
private func supervisorTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
    try TerminalServiceTLSIdentityStore.loadOrCreate(root: supervisorTestTLSRoot)
}

@MainActor final class SpacesDeviceAPISupervisorTests: XCTestCase {
    func testControlStatusWaitsForControlEndpointBeforeRelaunchingTerminalService() throws {
        var ensureCount = 0
        var relaunchCount = 0
        var statusCount = 0

        let response = try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService(
            timeout: 1,
            ensureRunning: { _ in
                ensureCount += 1
                return false
            },
            relaunch: { _ in
                relaunchCount += 1
                return true
            },
            status: { _ in
                statusCount += 1
                if statusCount == 1 { throw POSIXError(.ENOENT) }
                return SpacesDeviceAPIControlResponse(ok: true, message: "Loaded Device API status.")
            }, hasLiveTerminalSessions: { false }, retryInterval: 0)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(ensureCount, 1)
        XCTAssertEqual(relaunchCount, 0)
        XCTAssertEqual(statusCount, 2)
    }

    func testControlStatusRelaunchesTerminalServiceWhenControlEndpointStaysMissing() throws {
        var relaunchCount = 0
        var statusCount = 0

        let response = try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService(
            timeout: 0, ensureRunning: { _ in false },
            relaunch: { _ in
                relaunchCount += 1
                return true
            },
            status: { _ in
                statusCount += 1
                if statusCount == 1 { throw POSIXError(.ENOENT) }
                return SpacesDeviceAPIControlResponse(ok: true, message: "Loaded Device API status.")
            }, hasLiveTerminalSessions: { false })

        XCTAssertTrue(response.ok)
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertEqual(statusCount, 2)
    }

    func testControlStatusDoesNotRelaunchTerminalServiceForNonEndpointFailure() throws {
        var relaunchCount = 0

        XCTAssertThrowsError(
            try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService(
                timeout: 1, ensureRunning: { _ in false },
                relaunch: { _ in
                    relaunchCount += 1
                    return true
                }, status: { _ in throw POSIXError(.EACCES) }, hasLiveTerminalSessions: { false }))
        XCTAssertEqual(relaunchCount, 0)
    }

    func testControlStatusDoesNotRelaunchTerminalServiceWhenSessionsAreLive() throws {
        var relaunchCount = 0

        XCTAssertThrowsError(
            try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService(
                timeout: 1, ensureRunning: { _ in false },
                relaunch: { _ in
                    relaunchCount += 1
                    return true
                }, status: { _ in throw POSIXError(.ENOENT) }, hasLiveTerminalSessions: { true }))
        XCTAssertEqual(relaunchCount, 0)
    }

    func testControlResponseRelaunchesTerminalServiceWhenDeviceAPIReportsNotRunning() throws {
        var relaunchCount = 0
        var sendCount = 0

        let response = try SpacesDeviceAPIControlClient.responseEnsuringCurrentTerminalService(
            timeout: 1, ensureRunning: { _ in false },
            relaunch: { _ in
                relaunchCount += 1
                return true
            },
            send: { _ in
                sendCount += 1
                if sendCount < 3 { return SpacesDeviceAPIControlResponse(ok: false, message: "Device API is not running.") }
                return SpacesDeviceAPIControlResponse(ok: true, message: "Opened device pairing window.")
            }, hasLiveTerminalSessions: { false }, retryInterval: 0)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertEqual(sendCount, 3)
    }

    func testControlResponseKeepsRetryingAfterRelaunchConsumesInitialTimeout() throws {
        var relaunchCount = 0
        var sendCount = 0

        let response = try SpacesDeviceAPIControlClient.responseEnsuringCurrentTerminalService(
            timeout: 0.01, ensureRunning: { _ in false },
            relaunch: { _ in
                relaunchCount += 1
                Thread.sleep(forTimeInterval: 0.02)
                return true
            },
            send: { _ in
                sendCount += 1
                if sendCount == 1 { return SpacesDeviceAPIControlResponse(ok: false, message: "Device API is not running.") }
                return SpacesDeviceAPIControlResponse(ok: true, message: "Opened device pairing window.")
            }, hasLiveTerminalSessions: { false }, retryInterval: 0)

        XCTAssertTrue(response.ok)
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertEqual(sendCount, 2)
    }

    func testControlResponseDoesNotRelaunchTerminalServiceWhenDeviceAPIReportsNotRunningWithLiveSessions() throws {
        var relaunchCount = 0

        let response = try SpacesDeviceAPIControlClient.responseEnsuringCurrentTerminalService(
            timeout: 1, ensureRunning: { _ in false },
            relaunch: { _ in
                relaunchCount += 1
                return true
            }, send: { _ in SpacesDeviceAPIControlResponse(ok: false, message: "Device API is not running.") }, hasLiveTerminalSessions: { true })

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.message, "Device API is not running.")
        XCTAssertEqual(relaunchCount, 0)
    }

    func testStatusReportsUnavailableWhenConfiguredPortIsBusy() async throws {
        try await withTemporaryProfile { _ in
            let occupiedSocket = try makeOccupiedPortSocket()
            defer { close(occupiedSocket.fileDescriptor) }

            let environment = [SpacesDeviceAPIDefaults.portEnvironmentVariable: "\(occupiedSocket.port)"]
            let supervisor = SpacesDeviceAPISupervisor(
                settingsStore: SpacesDeviceAPISettingsStore(environment: environment), environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let response = try await Task.detached { try SpacesDeviceAPIControlClient.status() }.value
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.message, "Device API is not running.")
            XCTAssertEqual(response.status?.port, occupiedSocket.port)
            XCTAssertNil(response.pairingWindow)
        }
    }

    func testOpenPairingWindowReportsUnavailableWhenConfiguredPortIsBusy() async throws {
        try await withTemporaryProfile { _ in
            let occupiedSocket = try makeOccupiedPortSocket()
            defer { close(occupiedSocket.fileDescriptor) }

            let environment = [SpacesDeviceAPIDefaults.portEnvironmentVariable: "\(occupiedSocket.port)"]
            let supervisor = SpacesDeviceAPISupervisor(
                settingsStore: SpacesDeviceAPISettingsStore(environment: environment), environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let status = try supervisor.status()
            XCTAssertEqual(status.host, SpacesDeviceAPIDefaults.host)
            XCTAssertEqual(status.port, occupiedSocket.port)

            let response = try await Task.detached { try SpacesDeviceAPIControlClient.openPairingWindow() }.value
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.message, "Device API is not running.")
            XCTAssertEqual(response.status?.port, occupiedSocket.port)
            XCTAssertNil(response.pairingWindow)
        }
    }

    func testOpenPairingWindowDoesNotEmitIPv6WildcardHost() async throws {
        try await withTemporaryProfile { _ in
            let environment = [SpacesDeviceAPIDefaults.hostEnvironmentVariable: "::", SpacesDeviceAPIDefaults.portEnvironmentVariable: "0"]
            let supervisor = SpacesDeviceAPISupervisor(
                settingsStore: SpacesDeviceAPISettingsStore(environment: environment), environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let response = try await Task.detached { try SpacesDeviceAPIControlClient.openPairingWindow() }.value
            let linkString = try XCTUnwrap(response.pairingWindow?.linkString)
            let link = try SpacesDevicePairingLink.parse(linkString)

            XCTAssertTrue(response.ok)
            XCTAssertNotEqual(link.host, "::")
            XCTAssertFalse(SpacesDeviceAPIDefaults.isWildcardHost(link.host))
        }
    }

    func testWildcardPairingLinkHostPrefersHardwareLANAddress() {
        let activeFlags = IFF_UP | IFF_RUNNING
        let addresses = SpacesDeviceAPINetworkInterfaces.sortedIPv4Addresses(from: [
            .init(name: "utun4", address: "100.64.12.34", flags: activeFlags | IFF_POINTOPOINT, discoveryIndex: 0),
            .init(name: "vmnet8", address: "192.168.64.1", flags: activeFlags, discoveryIndex: 1),
            .init(name: "en0", address: "192.168.1.24", flags: activeFlags, discoveryIndex: 2),
            .init(name: "bridge100", address: "192.168.2.1", flags: activeFlags, discoveryIndex: 3),
        ])

        XCTAssertEqual(addresses.first, "192.168.1.24")
        XCTAssertEqual(SpacesDeviceAPINetworkInterfaces.pairingLinkHost(boundHost: "0.0.0.0", networkAddresses: addresses), "192.168.1.24")
    }

    func testOwnerGatedTerminalCommandsRequireMobileClientID() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-owner-gated-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()

            let recorder = DeviceAPITerminalControlRecorder()
            let controlServer = TerminalControlServer(
                socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.owner-gated.test")
            ) { request in
                recorder.record(request)
                return TerminalControlResponse(ok: true, message: "Forwarded terminal control request.")
            }
            try controlServer.start()
            defer { controlServer.stop() }

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-OWNER-GATED", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let rejectedRequests = [
                SpacesDeviceAPIRequest(
                    command: .terminalControl(.init(action: .send, sessionID: sessionID, text: "echo denied")), authToken: authToken,
                    clientApp: clientApp),
                SpacesDeviceAPIRequest(
                    command: .terminalControl(.init(action: .send, sessionID: sessionID, clientID: "   ", text: "echo denied")), authToken: authToken,
                    clientApp: clientApp),
                SpacesDeviceAPIRequest(
                    command: .terminalControl(.init(action: .key, sessionID: sessionID, key: "enter")), authToken: authToken, clientApp: clientApp),
                SpacesDeviceAPIRequest(
                    command: .terminalControl(.init(action: .resize, sessionID: sessionID, columns: 80, rows: 24)), authToken: authToken,
                    clientApp: clientApp),
                SpacesDeviceAPIRequest(
                    command: .terminalControl(.init(action: .scroll, sessionID: sessionID, scrollVertical: 24)), authToken: authToken,
                    clientApp: clientApp),
            ]

            for request in rejectedRequests {
                let response = try await Task.detached {
                    try Self.sendDeviceAPIRequest(request, port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                }.value

                XCTAssertFalse(response.ok)
                XCTAssertEqual(response.message, "Missing device client ID.")
            }

            XCTAssertTrue(recorder.requests().isEmpty)

            let acceptedResponse = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(
                        command: .terminalControl(
                            .init(
                                action: .resize, sessionID: sessionID, clientID: "ios-client", columns: 80, rows: 24, ownerEpoch: 11, resizeSerial: 5)
                        ), authToken: authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertTrue(acceptedResponse.ok)
            let forwardedResize = try XCTUnwrap(recorder.requests().first)
            XCTAssertEqual(forwardedResize.command, "resize")
            XCTAssertEqual(forwardedResize.clientID, "ios-client")
            XCTAssertEqual(forwardedResize.ownerEpoch, 11)
            XCTAssertEqual(forwardedResize.resizeSerial, 5)

            let acceptedScrollResponse = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(
                        command: .terminalControl(
                            .init(action: .scroll, sessionID: sessionID, clientID: "ios-client", ownerEpoch: 12, scrollVertical: 24, scrollMods: 7)),
                        authToken: authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertTrue(acceptedScrollResponse.ok)
            let forwardedScroll = try XCTUnwrap(recorder.requests().last)
            XCTAssertEqual(forwardedScroll.command, "scroll")
            XCTAssertEqual(forwardedScroll.clientID, "ios-client")
            XCTAssertEqual(forwardedScroll.ownerEpoch, 12)
            XCTAssertEqual(forwardedScroll.scrollVertical, 24)
            XCTAssertEqual(forwardedScroll.scrollMods, 7)
        }
    }

    func testTakeoverResponseAcknowledgesWithoutEmbeddingTerminalState() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-takeover-ack-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "takeover", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                    command: "cat", createdAt: "2026-05-29T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            let recorder = DeviceAPITerminalControlRecorder()
            let controlServer = TerminalControlServer(
                socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.takeover-state.test")
            ) { request in
                recorder.record(request)
                return TerminalControlResponse(ok: true, message: "Transferred terminal ownership.")
            }
            try controlServer.start()
            defer { controlServer.stop() }

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-TAKEOVER-STATE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(
                        command: .terminalControl(.init(action: .takeover, sessionID: sessionID, clientID: "ios-client")), authToken: authToken,
                        clientApp: clientApp), port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertTrue(response.ok)
            XCTAssertNil(response.sessionState)
            XCTAssertEqual(recorder.requests().first?.command, "takeover")
            XCTAssertEqual(recorder.requests().first?.clientID, "ios-client")
        }
    }

    func testControlCFromMobileTargetsOnlyRequestedSession() async throws {
        try await withTemporaryProfile { _ in
            let interruptSessionID = "session-interrupt-target-\(UUID().uuidString)"
            let survivorSessionID = "session-survivor-peer-\(UUID().uuidString)"
            let interruptPaths = try TerminalSessionPaths.forSession(id: interruptSessionID)
            let survivorPaths = try TerminalSessionPaths.forSession(id: survivorSessionID)
            try interruptPaths.ensureDirectories()
            try survivorPaths.ensureDirectories()

            let interruptRecorder = DeviceAPITerminalControlRecorder()
            let survivorRecorder = DeviceAPITerminalControlRecorder()
            let interruptControlServer = TerminalControlServer(
                socketPath: interruptPaths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.ctrl-c.interrupt-target")
            ) { request in
                interruptRecorder.record(request)
                return TerminalControlResponse(ok: true, message: "Sent key.")
            }
            let survivorControlServer = TerminalControlServer(
                socketPath: survivorPaths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.ctrl-c.survivor-peer")
            ) { request in
                survivorRecorder.record(request)
                return TerminalControlResponse(ok: true, message: "Sent key.")
            }
            try interruptControlServer.start()
            try survivorControlServer.start()
            defer {
                interruptControlServer.stop()
                survivorControlServer.stop()
            }

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-CTRL-C", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(
                        command: .terminalControl(
                            .init(action: .key, sessionID: interruptSessionID, clientID: "ios-owner", key: "ctrl+c", ownerEpoch: 3)),
                        authToken: authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertTrue(response.ok)
            XCTAssertEqual(
                interruptRecorder.requests(), [TerminalControlRequest(command: "key", key: "ctrl+c", clientID: "ios-owner", ownerEpoch: 3)])
            XCTAssertTrue(survivorRecorder.requests().isEmpty)
        }
    }

    func testOverviewFiltersConfiguredWorkspaceRowsWithDeadInteractiveServicePID() async throws {
        try await withTemporaryProfile { root in
            let store = try SQLiteStore(path: root.appendingPathComponent("spaces.db").path)
            let projectDir = root.appendingPathComponent("project", isDirectory: true)
            let workspaceDir = projectDir.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

            let project = ProjectRecord(id: "project-dead-service", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
            let workspace = WorkspaceRecord(
                id: "workspace-dead-service", projectID: project.id, dir: workspaceDir.path, dirname: nil, branch: "main", isDefault: false,
                isArchived: false, isRunning: true, lastLaunchedAt: nil)
            try store.upsert(project: project)
            try store.upsert(workspace: workspace)

            let sessionID = "session-dead-service-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "dead-process", workingDirectory: workspaceDir.path, shell: "/bin/zsh",
                    command: "sleep 300", createdAt: "2026-06-04T12:00:00Z", workspaceID: workspace.id, kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 999_999, childPID: nil, state: .running,
                    updatedAt: "2026-06-04T12:00:01Z", title: "dead-process", workingDirectory: workspaceDir.path), paths: paths)
            try store.upsert(
                runningProcess: RunningProcessRecord(
                    id: "process-dead-service", workspaceID: workspace.id, templateName: "dead-process", command: "sleep 300",
                    terminalApp: TerminalHost.spaces.appName, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil, status: .running,
                    logPath: nil, lastOutputAt: nil, startedAt: "2026-06-04T12:00:00Z", exitedAt: nil))

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-DEAD-SERVICE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(command: .overview, authToken: authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertTrue(response.ok)
            let overview = try XCTUnwrap(response.overview)
            XCTAssertFalse(overview.sessions.contains { $0.id == sessionID })
            XCTAssertEqual(overview.workspaces.first(where: { $0.id == workspace.id })?.sessionCount, 0)
        }
    }

    func testStateRequestReturnsLiveStateInsteadOfOutputLog() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-live-state-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "live", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: "cat",
                    createdAt: "2026-05-26T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)

            try Data("\u{1B}[32mOUTPUT-LOG-SHOULD-NOT-APPEAR\u{1B}[0m\n".utf8).write(to: URL(fileURLWithPath: paths.outputPath))
            let liveState = Self.liveTerminalStatePayload(sessionID: sessionID, snapshotText: "LIVE-STATE")
            let subscriptionServer = DeviceAPITestSubscriptionServer(socketPath: paths.subscriptionSocketPath, payload: liveState)
            try subscriptionServer.start()
            defer { subscriptionServer.stop() }

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-LIVE-STATE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID)), authToken: authToken, clientApp: clientApp),
                    port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertEqual(response.sessionState?.renderText, "LIVE-STATE")
            XCTAssertNil(response.sessionState?.outputByteCount)
            XCTAssertNil(response.sessionState?.outputEndByteOffset)
        }
    }

    func testRevokeDeviceClosesActiveSubscribeConnection() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-revoke-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            let subscriptionServer = DeviceAPITestSubscriptionServer(socketPath: paths.subscriptionSocketPath)
            try subscriptionServer.start()
            defer { subscriptionServer.stop() }

            let environment = [SpacesDeviceAPIDefaults.portEnvironmentVariable: "\(try makeAvailablePort())"]
            let settingsStore = SpacesDeviceAPISettingsStore(environment: environment)

            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-REVOKE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)

            let supervisor = SpacesDeviceAPISupervisor(settingsStore: settingsStore, environment: environment, restartInterval: 60)
            supervisor.start()
            defer { supervisor.stop() }

            let status = try supervisor.status()
            let connection = try startSubscribeConnection(
                sessionID: sessionID, clientApp: clientApp, authToken: authToken, port: status.port,
                certificateFingerprint: status.certificateFingerprint)
            defer { connection.cancel() }

            XCTAssertTrue(subscriptionServer.waitForAccepted(timeout: 5))

            let response = try await Task.detached { try SpacesDeviceAPIControlClient.revokeDevice(installationID: clientApp.installationID) }.value
            XCTAssertTrue(response.ok)
            XCTAssertTrue(waitForConnectionClosure(connection, timeout: 5))
        }
    }

    func testSubscribeDeliversFinalPayloadBeforeClosingStream() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-final-stream-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            let finalPayload = GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T12:46:31Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: 200, state: .exited,
                    updatedAt: "2026-06-04T12:46:31Z", exitedAt: "2026-06-04T12:46:31Z", title: "final-target", workingDirectory: "/tmp/work",
                    columns: 5, rows: 1), attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-target",
                workingDirectory: "/tmp/work", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(
                    .full(.init(sessionRevision: 2, ownerEpoch: 1, snapshot: Self.ghosttySnapshot(text: "FINAL")))))
            let subscriptionServer = DeviceAPITestSubscriptionServer(
                socketPath: paths.subscriptionSocketPath, payload: finalPayload, closeAfterPayload: true)
            try subscriptionServer.start()
            defer { subscriptionServer.stop() }

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-FINAL-STREAM", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let connection = try startSubscribeConnection(
                sessionID: sessionID, clientApp: clientApp, authToken: authToken, port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)
            defer { connection.cancel() }

            let receivedPayload = try readStreamPayload(connection, timeout: 5)

            XCTAssertEqual(receivedPayload.reason, TerminalRemoteSessionStateReason.terminated)
            XCTAssertEqual(receivedPayload.renderText, "FINAL")
            XCTAssertTrue(waitForConnectionClosure(connection, timeout: 5))
        }
    }

    func testSubscribeDrainsQueuedFinalPayloadWhenEOFArrivesAfterEAGAIN() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-final-stream-delayed-eof-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            let finalPayload = GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T12:46:31Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2,
                runtimeState: TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: 200, state: .exited,
                    updatedAt: "2026-06-04T12:46:31Z", exitedAt: "2026-06-04T12:46:31Z", title: "final-target", workingDirectory: "/tmp/work",
                    columns: 5, rows: 1), attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "final-target",
                workingDirectory: "/tmp/work", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(
                    .full(.init(sessionRevision: 2, ownerEpoch: 1, snapshot: Self.ghosttySnapshot(text: "FINAL")))))
            let subscriptionServer = DeviceAPITestSubscriptionServer(
                socketPath: paths.subscriptionSocketPath, payload: finalPayload, closeAfterPayload: true, closeDelayAfterPayload: 0.1)
            try subscriptionServer.start()
            defer { subscriptionServer.stop() }

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-FINAL-STREAM-DELAYED-EOF", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let pairingStore = try SpacesDevicePairingStore()
            let authToken = try pairingStore.issueToken(for: clientApp)
            let server = SpacesDeviceAPIServer(
                host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                networkEnvironment: [
                    "SPACES_DEVICE_API_NETWORK_PROFILE": "test-delayed", "SPACES_DEVICE_API_NETWORK_RTT_MS": "1000",
                    "SPACES_DEVICE_API_NETWORK_BANDWIDTH_BPS": "0", "SPACES_DEVICE_API_NETWORK_CHUNK_BYTES": "0",
                ])
            try server.start()
            defer { server.stop() }

            let connection = try startSubscribeConnection(
                sessionID: sessionID, clientApp: clientApp, authToken: authToken, port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)
            defer { connection.cancel() }

            let receivedPayload = try readStreamPayload(connection, timeout: 5)

            XCTAssertEqual(receivedPayload.reason, TerminalRemoteSessionStateReason.terminated)
            XCTAssertEqual(receivedPayload.renderText, "FINAL")
            XCTAssertTrue(waitForConnectionClosure(connection, timeout: 5))
        }
    }

    func testSubscribeToEndedSessionWithoutLiveSocketDeliversPersistedFinalPayload() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-ended-subscribe-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "final-target", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                    command: "sleep 300", createdAt: "2026-06-04T14:23:10Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            let runtimeState = TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: 200, state: .exited, updatedAt: "2026-06-04T14:23:23Z",
                exitedAt: "2026-06-04T14:23:23Z", title: "final-target", workingDirectory: "/tmp/work", columns: 5, rows: 1)
            try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
            let finalPayload = GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T14:23:23Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-target", workingDirectory: "/tmp/work", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(
                    .full(.init(sessionRevision: 2, ownerEpoch: 1, snapshot: Self.ghosttySnapshot(text: "FINAL")))))
            try TerminalSessionPersistence.writeRemoteSessionState(finalPayload, paths: paths)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-ENDED-SUBSCRIBE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let connection = try startSubscribeConnection(
                sessionID: sessionID, clientApp: clientApp, authToken: authToken, port: server.listeningPort,
                certificateFingerprint: identity.certificateFingerprint)
            defer { connection.cancel() }

            let receivedPayload = try readStreamPayload(connection, timeout: 5)

            XCTAssertEqual(receivedPayload.reason, TerminalRemoteSessionStateReason.terminated)
            XCTAssertEqual(receivedPayload.renderText, "FINAL")
            XCTAssertTrue(waitForConnectionClosure(connection, timeout: 5))
        }
    }

    func testStateRequestForEndedSessionWithoutLiveSocketReturnsPersistedFinalPayload() async throws {
        try await withTemporaryProfile { _ in
            let sessionID = "session-ended-state-\(UUID().uuidString)"
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                .init(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "final-target", workingDirectory: "/tmp/work", shell: "/bin/zsh",
                    command: "sleep 300", createdAt: "2026-06-04T14:23:10Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            let runtimeState = TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 100, childPID: 200, state: .exited, updatedAt: "2026-06-04T14:23:23Z",
                exitedAt: "2026-06-04T14:23:23Z", title: "final-target", workingDirectory: "/tmp/work", columns: 5, rows: 1)
            try TerminalSessionPersistence.writeRuntimeState(runtimeState, paths: paths)
            let finalPayload = GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.terminated, emittedAt: "2026-06-04T14:23:23Z", sessionStateRevision: 2,
                sessionStateFlags: 1, screenStateRevision: 2, runtimeState: runtimeState, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                title: "final-target", workingDirectory: "/tmp/work", outputByteCount: nil,
                renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(
                    .full(.init(sessionRevision: 2, ownerEpoch: 1, snapshot: Self.ghosttySnapshot(text: "FINAL")))))
            try TerminalSessionPersistence.writeRemoteSessionState(finalPayload, paths: paths)
            try? FileManager.default.removeItem(atPath: paths.subscriptionSocketPath)

            let identity = try supervisorTestTLSIdentity()
            let clientApp = SpacesDeviceClientApp(
                installationID: "INSTALLATION-ENDED-STATE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios",
                deviceName: "iPhone", appVersion: "1.0")
            let authToken = try SpacesDevicePairingStore().issueToken(for: clientApp)
            let server = try SpacesDeviceAPIServer(host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity)
            try server.start()
            defer { server.stop() }

            let response = try await Task.detached {
                try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(command: .state(.init(sessionID: sessionID)), authToken: authToken, clientApp: clientApp),
                    port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
            }.value

            XCTAssertTrue(response.ok)
            XCTAssertEqual(response.sessionState?.reason, TerminalRemoteSessionStateReason.terminated)
            XCTAssertEqual(response.sessionState?.renderText, "FINAL")
        }
    }

    func testRevokePairingWaitsForInFlightDeviceAPIAuthorizationBeforeSaving() throws {
        let identity = try supervisorTestTLSIdentity()
        let clientApp = SpacesDeviceClientApp(
            installationID: "INSTALLATION-REVOKE-RACE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
            appVersion: "1.0")
        let pairingStore = BlockingAuthorizePairingStore(clientApp: clientApp)
        let server = SpacesDeviceAPIServer(
            host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let requestFinished = DispatchSemaphore(value: 0)
        let requestResult = DeviceAPISupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
                requestResult.setResponse(response)
            } catch { requestResult.setError(error) }
            requestFinished.signal()
        }

        XCTAssertTrue(pairingStore.waitForAuthorizeStarted(timeout: 5))

        let revokeFinished = DispatchSemaphore(value: 0)
        let revokeResult = DeviceAPISupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do { revokeResult.setDevices(try server.revokePairing(installationID: clientApp.installationID)) } catch { revokeResult.setError(error) }
            revokeFinished.signal()
        }

        if revokeFinished.wait(timeout: .now() + 0.2) == .success {
            XCTFail("revoke should wait for the in-flight Device API authorization to finish")
        }

        pairingStore.finishAuthorize()

        guard requestFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for the Device API request")
            return
        }
        guard revokeFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for revoke")
            return
        }

        XCTAssertNil(requestResult.error())
        XCTAssertEqual(requestResult.response()?.ok, true)
        XCTAssertNil(revokeResult.error())
        XCTAssertEqual(revokeResult.devices(), [])
        XCTAssertEqual(try pairingStore.listDevices(), [])
    }

    func testResetPairingsWaitsForInFlightDeviceAPIAuthorizationBeforeSaving() throws {
        let identity = try supervisorTestTLSIdentity()
        let clientApp = SpacesDeviceClientApp(
            installationID: "INSTALLATION-RESET-RACE", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
            appVersion: "1.0")
        let pairingStore = BlockingAuthorizePairingStore(clientApp: clientApp)
        let server = SpacesDeviceAPIServer(
            host: SpacesDeviceAPIDefaults.loopbackHost, port: 0, identity: identity, pairingStoreProtocol: pairingStore)
        try server.start()
        defer { server.stop() }

        let requestFinished = DispatchSemaphore(value: 0)
        let requestResult = DeviceAPISupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try Self.sendDeviceAPIRequest(
                    SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp), port: server.listeningPort,
                    certificateFingerprint: identity.certificateFingerprint)
                requestResult.setResponse(response)
            } catch { requestResult.setError(error) }
            requestFinished.signal()
        }

        XCTAssertTrue(pairingStore.waitForAuthorizeStarted(timeout: 5))

        let resetFinished = DispatchSemaphore(value: 0)
        let resetResult = DeviceAPISupervisorTestResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.resetPairingsAndStop()
                resetResult.setFlag(true)
            } catch { resetResult.setError(error) }
            resetFinished.signal()
        }

        if resetFinished.wait(timeout: .now() + 0.2) == .success { XCTFail("reset should wait for the in-flight Device API authorization to finish") }

        pairingStore.finishAuthorize()

        guard resetFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for reset")
            return
        }
        guard requestFinished.wait(timeout: .now() + 5) == .success else {
            XCTFail("timed out waiting for the Device API request")
            return
        }

        XCTAssertNil(resetResult.error())
        XCTAssertTrue(resetResult.flag())
        XCTAssertEqual(try pairingStore.listDevices(), [])
    }

    private func makeOccupiedPortSocket() throws -> (fileDescriptor: Int32, port: Int) {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr(SpacesDeviceAPIDefaults.loopbackHost))
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fileDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard Darwin.listen(fileDescriptor, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            var boundAddress = sockaddr_in()
            var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    getsockname(fileDescriptor, sockaddrPointer, &boundAddressLength)
                }
            }
            guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return (fileDescriptor, Int(UInt16(bigEndian: boundAddress.sin_port)))
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private func makeAvailablePort() throws -> Int {
        let socket = try makeOccupiedPortSocket()
        close(socket.fileDescriptor)
        return socket.port
    }

    private func startSubscribeConnection(
        sessionID: String, clientApp: SpacesDeviceClientApp, authToken: String, port: Int, certificateFingerprint: String
    ) throws -> NWConnection {
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.device.api.supervisor.subscribe.test")
        let resultBox = DeviceAPISupervisorTestResultBox()
        let connection = NWConnection(
            host: NWEndpoint.Host(SpacesDeviceAPIDefaults.loopbackHost), port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))),
            using: SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint))

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                resultBox.setError(error)
                ready.signal()
                sent.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            connection.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = resultBox.error() {
            connection.cancel()
            throw error
        }

        var requestData = try SpacesDeviceAPICodec.encodeRequest(
            SpacesDeviceAPIRequest(
                command: .subscribe(.init(sessionID: sessionID, clientID: "device-client-revoke")), authToken: authToken, clientApp: clientApp))
        requestData.append(0x0A)
        connection.send(
            content: requestData,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        guard sent.wait(timeout: .now() + 5) == .success else {
            connection.cancel()
            throw POSIXError(.ETIMEDOUT)
        }
        if let error = resultBox.error() {
            connection.cancel()
            throw error
        }

        return connection
    }

    private func waitForConnectionClosure(_ connection: NWConnection, timeout: TimeInterval) -> Bool {
        let finished = DispatchSemaphore(value: 0)
        let resultBox = DeviceAPISupervisorTestResultBox()

        @Sendable func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if isComplete || error != nil {
                    resultBox.setFlag(true)
                    finished.signal()
                    return
                }
                receiveNext()
            }
        }
        receiveNext()

        guard finished.wait(timeout: .now() + timeout) == .success else { return false }
        return resultBox.flag()
    }

    private func readStreamPayload(_ connection: NWConnection, timeout: TimeInterval) throws -> GhosttyRemoteSessionStatePayload {
        let received = DispatchSemaphore(value: 0)
        let resultBox = DeviceAPISupervisorTestResultBox()

        @Sendable func receiveNext(_ data: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let error {
                    resultBox.setError(error)
                    received.signal()
                    return
                }
                var nextData = data
                if let content, !content.isEmpty { nextData.append(content) }
                if let newlineIndex = nextData.firstIndex(of: 0x0A) {
                    resultBox.appendData(Data(nextData.prefix(upTo: newlineIndex)))
                    received.signal()
                    return
                }
                if isComplete {
                    resultBox.appendData(nextData)
                    received.signal()
                    return
                }
                receiveNext(nextData)
            }
        }
        receiveNext(Data())

        guard received.wait(timeout: .now() + timeout) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }
        return try GhosttyRemoteSessionStateCodec.decodeLine(resultBox.responseData())
    }

    nonisolated private static func sendDeviceAPIRequest(_ request: SpacesDeviceAPIRequest, port: Int, certificateFingerprint: String) throws
        -> SpacesDeviceAPIResponse
    {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw POSIXError(.EINVAL) }
        let ready = DispatchSemaphore(value: 0)
        let sent = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "spaces.device.api.supervisor.request.test")
        let resultBox = DeviceAPISupervisorTestResultBox()
        let connection = NWConnection(
            host: NWEndpoint.Host(SpacesDeviceAPIDefaults.loopbackHost), port: nwPort,
            using: SpacesPinnedTLSConnector.tlsParameters(certificateFingerprint: certificateFingerprint))
        defer { connection.cancel() }

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
        guard ready.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }

        var requestData = try SpacesDeviceAPICodec.encodeRequest(request)
        requestData.append(0x0A)
        connection.send(
            content: requestData,
            completion: .contentProcessed { error in
                if let error { resultBox.setError(error) }
                sent.signal()
            })
        guard sent.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }

        @Sendable func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    resultBox.appendData(content)
                    if resultBox.responseData().contains(0x0A) {
                        received.signal()
                        return
                    }
                }
                if let error {
                    resultBox.setError(error)
                    received.signal()
                    return
                }
                if isComplete {
                    received.signal()
                    return
                }
                receiveNext()
            }
        }
        receiveNext()

        guard received.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
        if let error = resultBox.error() { throw error }
        return try SpacesDeviceAPICodec.decodeResponse(resultBox.responseData())
    }

    nonisolated private static func liveTerminalStatePayload(sessionID: String, snapshotText: String) -> GhosttyRemoteSessionStatePayload {
        let snapshot = ghosttySnapshot(text: snapshotText)
        let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 0, snapshot: snapshot)
        return GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: "live_state", emittedAt: GhosttyRemoteSessionStateTimestamp.string(from: Date()), sessionStateRevision: 1,
            sessionStateFlags: nil, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: TerminalSessionAttachmentSnapshot(), title: "live",
            workingDirectory: "/tmp/work", outputByteCount: nil, outputEndByteOffset: nil,
            renderUpdate: try? GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
    }

    nonisolated private static func ghosttySnapshot(text: String) -> GhosttyTerminalSnapshot {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let columns = rows.map(\.count).max() ?? 0
        let paddedRows = rows.map { row in row.padding(toLength: columns, withPad: " ", startingAt: 0) }
        let cells = paddedRows.flatMap { row in
            row.unicodeScalars.map { scalar in
                GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xFFFFFF, backgroundRGB: 0x000000, flags: 0)
            }
        }
        return GhosttyTerminalSnapshot(
            columns: columns, rows: paddedRows.count, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xFFFFFF,
            defaultBackgroundRGB: 0x000000, cells: cells)
    }

    private func withTemporaryProfile(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
        let originalRuntimePath = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
        setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
        setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime").path, 1)
        defer {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimePath { setenv("SPACES_RUNTIME_DIR", originalRuntimePath, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        try await body(root)
    }
}

private final class DeviceAPISupervisorTestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedFlag = false
    private var storedData = Data()
    private var storedDevices: [SpacesDevicePairedClient]?
    private var storedResponse: SpacesDeviceAPIResponse?

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

    func setFlag(_ flag: Bool) {
        lock.lock()
        storedFlag = flag
        lock.unlock()
    }

    func flag() -> Bool {
        lock.lock()
        let flag = storedFlag
        lock.unlock()
        return flag
    }

    func appendData(_ data: Data) {
        lock.lock()
        storedData.append(data)
        lock.unlock()
    }

    func responseData() -> Data {
        lock.lock()
        let data = storedData
        lock.unlock()
        return data
    }

    func setDevices(_ devices: [SpacesDevicePairedClient]) {
        lock.lock()
        storedDevices = devices
        lock.unlock()
    }

    func devices() -> [SpacesDevicePairedClient]? {
        lock.lock()
        let devices = storedDevices
        lock.unlock()
        return devices
    }

    func setResponse(_ response: SpacesDeviceAPIResponse) {
        lock.lock()
        storedResponse = response
        lock.unlock()
    }

    func response() -> SpacesDeviceAPIResponse? {
        lock.lock()
        let response = storedResponse
        lock.unlock()
        return response
    }
}

private final class DeviceAPITerminalControlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [TerminalControlRequest] = []

    func record(_ request: TerminalControlRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    func requests() -> [TerminalControlRequest] {
        lock.lock()
        let requests = storedRequests
        lock.unlock()
        return requests
    }
}

private final class BlockingAuthorizePairingStore: SpacesDevicePairingStoreProtocol, @unchecked Sendable {
    let authToken = "AUTH-TOKEN"

    private let clientApp: SpacesDeviceClientApp
    private let authorizeStarted = DispatchSemaphore(value: 0)
    private let authorizeCanFinish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isPaired = true

    init(clientApp: SpacesDeviceClientApp) { self.clientApp = clientApp }

    func issueToken(for clientApp: SpacesDeviceClientApp, presentedToken _: String?) throws -> String {
        try validate(clientApp: clientApp)
        lock.lock()
        isPaired = true
        lock.unlock()
        return authToken
    }

    func listDevices() throws -> [SpacesDevicePairedClient] {
        lock.lock()
        let paired = isPaired
        lock.unlock()
        guard paired else { return [] }
        return [
            SpacesDevicePairedClient(
                installationID: clientApp.installationID, bundleID: clientApp.bundleID, platform: clientApp.platform,
                deviceName: clientApp.deviceName, appVersion: clientApp.appVersion, createdAt: "2026-01-01T00:00:00Z",
                lastUsedAt: "2026-01-01T00:00:01Z")
        ]
    }

    func revoke(installationID: String) throws {
        guard installationID.trimmingCharacters(in: .whitespacesAndNewlines) == clientApp.installationID else { return }
        lock.lock()
        isPaired = false
        lock.unlock()
    }

    func removeAll() throws {
        lock.lock()
        isPaired = false
        lock.unlock()
    }

    func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
        guard let clientApp else { throw SpacesDevicePairingError.missingClientApp }
        try validate(clientApp: clientApp)
        guard authToken == self.authToken else { throw SpacesDevicePairingError.invalidAuthToken }

        authorizeStarted.signal()
        guard authorizeCanFinish.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }

        lock.lock()
        isPaired = true
        lock.unlock()
    }

    func validate(clientApp: SpacesDeviceClientApp) throws {
        guard clientApp.bundleID == SpacesDeviceFirstPartyPolicy.allowedBundleID else {
            throw SpacesDevicePairingError.unsupportedBundle(clientApp.bundleID)
        }
        guard clientApp.installationID == self.clientApp.installationID else {
            throw SpacesDevicePairingError.unpairedInstallation(clientApp.installationID)
        }
    }

    func waitForAuthorizeStarted(timeout: TimeInterval) -> Bool { authorizeStarted.wait(timeout: .now() + timeout) == .success }

    func finishAuthorize() { authorizeCanFinish.signal() }
}

private final class DeviceAPITestSubscriptionServer: @unchecked Sendable {
    private let socketPath: String
    private let payload: GhosttyRemoteSessionStatePayload?
    private let closeAfterPayload: Bool
    private let closeDelayAfterPayload: TimeInterval
    private let queue = DispatchQueue(label: "spaces.device.api.supervisor.subscription.test")
    private let accepted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var listenSocketFD: Int32 = -1
    private var clientSocketFD: Int32 = -1

    init(
        socketPath: String, payload: GhosttyRemoteSessionStatePayload? = nil, closeAfterPayload: Bool = false,
        closeDelayAfterPayload: TimeInterval = 0
    ) {
        self.socketPath = socketPath
        self.payload = payload
        self.closeAfterPayload = closeAfterPayload
        self.closeDelayAfterPayload = closeDelayAfterPayload
    }

    func start() throws {
        try? FileManager.default.removeItem(atPath: socketPath)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        do {
            var address = try makeSocketAddress(path: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard listen(socketFD, 1) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            listenSocketFD = socketFD
            queue.async { [weak self] in self?.acceptConnection() }
        } catch {
            close(socketFD)
            throw error
        }
    }

    func waitForAccepted(timeout: TimeInterval) -> Bool { accepted.wait(timeout: .now() + timeout) == .success }

    func stop() {
        lock.lock()
        let clientFD = clientSocketFD
        let listenFD = listenSocketFD
        clientSocketFD = -1
        listenSocketFD = -1
        lock.unlock()

        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
        }
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptConnection() {
        let socketFD = currentListenSocket()
        guard socketFD >= 0 else { return }
        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { return }
        lock.lock()
        clientSocketFD = clientFD
        lock.unlock()
        accepted.signal()
        writePayloadIfNeeded(to: clientFD)
        if closeAfterPayload {
            if closeDelayAfterPayload > 0 {
                queue.asyncAfter(deadline: .now() + closeDelayAfterPayload) { [weak self] in self?.closeClientSocket(clientFD) }
            } else {
                closeClientSocket(clientFD)
            }
        }
    }

    private func closeClientSocket(_ clientFD: Int32) {
        shutdown(clientFD, SHUT_RDWR)
        close(clientFD)
        lock.lock()
        if clientSocketFD == clientFD { clientSocketFD = -1 }
        lock.unlock()
    }

    private func currentListenSocket() -> Int32 {
        lock.lock()
        let socketFD = listenSocketFD
        lock.unlock()
        return socketFD
    }

    private func writePayloadIfNeeded(to socketFD: Int32) {
        guard let payload, var data = try? GhosttyRemoteSessionStateCodec.encodeLine(payload) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(socketFD, baseAddress, buffer.count)
        }
    }

    private func makeSocketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8Path = path.utf8CString
        guard utf8Path.count <= maxLength else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
            _ = utf8Path.withUnsafeBufferPointer { buffer in memcpy(pointer, buffer.baseAddress, buffer.count) }
        }
        return address
    }
}
