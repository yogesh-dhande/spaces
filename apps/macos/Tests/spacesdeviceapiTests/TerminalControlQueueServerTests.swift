#if canImport(Network) && canImport(Security)
    import Darwin
    import Foundation
    import XCTest
    import workspacecore

    @testable import spacesdeviceapi
    @testable import spacesdevicecore
    @testable import spacesterminalcore

    /// Two request shapes wait on a target session's engine: a terminal command, over that session's
    /// control socket, and a `.state` catch-up read, through the live-core export. While either wait is
    /// outstanding the daemon still has to answer everything else, because a client whose input send timed
    /// out asks exactly this daemon whether the link is alive before it tears its stream down.
    final class TerminalControlQueueServerTests: XCTestCase {
        func testAStalledTerminalControlDoesNotDelayAPingOnAnotherConnection() throws {
            try withTemporaryProfile {
                let sessionID = "session-control-queue-\(UUID().uuidString)"
                let paths = try seedRunningSession(sessionID: sessionID)

                // Stands in for an engine saturated by output: it accepts the control connection and never
                // answers, so the command occupies whatever queue runs it for the client's full timeout.
                let controlRequestArrived = DispatchSemaphore(value: 0)
                let releaseControlRequest = DispatchSemaphore(value: 0)
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.control-queue.test")
                ) { _ in
                    controlRequestArrived.signal()
                    releaseControlRequest.wait()
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer {
                    releaseControlRequest.signal()
                    controlServer.stop()
                }

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "control-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let inputClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { inputClient.cancel() }
                let inputFinished = expectation(description: "The stalled terminal control eventually returns.")
                DispatchQueue.global().async {
                    _ = try? inputClient.send(
                        SpacesDeviceAPIRequest(
                            command: .terminalControl(
                                SpacesDeviceTerminalControlRequest(action: .send, sessionID: sessionID, clientID: "client-control-queue", text: "ls")),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    inputFinished.fulfill()
                }
                XCTAssertEqual(controlRequestArrived.wait(timeout: .now() + 5), .success, "The terminal control must reach the stalled session.")

                let probeClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 2)
                let startedAt = Date()
                let pong = try probeClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(pong.ok, pong.message)
                XCTAssertEqual(pong.message, "pong")
                XCTAssertLessThan(elapsed, 1.5, "A ping must not wait behind a terminal command stalled on its session's engine.")

                releaseControlRequest.signal()
                wait(for: [inputFinished], timeout: 10)
            }
        }

        /// The other engine-blocking shape: a `.state` catch-up read for a session this daemon hosts live
        /// exports the frame straight out of the session's core, so it waits on the same saturated engine
        /// the control commands do. A pane resyncing while it types issues exactly this pair, and the
        /// `.state` must not be what makes the probe's ping miss its deadline.
        func testAStalledStateReadDoesNotDelayAPingOnAnotherConnection() throws {
            try withTemporaryProfile {
                let sessionID = "session-state-queue-\(UUID().uuidString)"
                _ = try seedRunningSession(sessionID: sessionID)

                // Stands in for `TerminalEngineActor.runSynchronously` on a saturated engine: the live-core
                // export blocks until released, occupying whatever queue runs the `.state` request.
                let stateRequestArrived = DispatchSemaphore(value: 0)
                let releaseStateRequest = DispatchSemaphore(value: 0)
                let statePayload = try liveStatePayload(sessionID: sessionID)
                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                    liveTerminalSessionStateProvider: { _ in
                        stateRequestArrived.signal()
                        releaseStateRequest.wait()
                        return statePayload
                    })
                try server.start()
                defer {
                    releaseStateRequest.signal()
                    server.stop()
                }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "control-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let stateClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { stateClient.cancel() }
                let stateFinished = expectation(description: "The stalled state read eventually returns.")
                DispatchQueue.global().async {
                    _ = try? stateClient.send(
                        SpacesDeviceAPIRequest(
                            command: .state(SpacesDeviceTerminalSessionRequest(sessionID: sessionID)), authToken: pairingStore.authToken,
                            clientApp: clientApp))
                    stateFinished.fulfill()
                }
                XCTAssertEqual(stateRequestArrived.wait(timeout: .now() + 5), .success, "The state read must reach the stalled live core.")

                let probeClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 2)
                let startedAt = Date()
                let pong = try probeClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(pong.ok, pong.message)
                XCTAssertEqual(pong.message, "pong")
                XCTAssertLessThan(elapsed, 1.5, "A ping must not wait behind a state read stalled on its session's engine.")

                releaseStateRequest.signal()
                wait(for: [stateFinished], timeout: 10)
            }
        }

        /// The cross-session guarantee the per-session lanes exist for. Before them every session's
        /// controls and `.state` exports shared one serial queue, so a keystroke for one pane waited behind
        /// however many other sessions were mid-round-trip — each able to hold the queue for the client's
        /// full 5s control deadline, which is why the freeze appeared at roughly five streaming agents.
        /// A control stalled on one session's engine must now leave another session's control untouched.
        func testAStalledControlOnOneSessionDoesNotDelayAControlOnAnotherSession() throws {
            try withTemporaryProfile {
                let stalledSessionID = "session-lane-stalled-\(UUID().uuidString)"
                let respondingSessionID = "session-lane-responding-\(UUID().uuidString)"
                let stalledPaths = try seedRunningSession(sessionID: stalledSessionID)
                let respondingPaths = try seedRunningSession(sessionID: respondingSessionID)

                let stalledRequestArrived = DispatchSemaphore(value: 0)
                let releaseStalledRequest = DispatchSemaphore(value: 0)
                let stalledControlServer = TerminalControlServer(
                    socketPath: stalledPaths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.lane.stalled.test")
                ) { _ in
                    stalledRequestArrived.signal()
                    releaseStalledRequest.wait()
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try stalledControlServer.start()
                defer {
                    releaseStalledRequest.signal()
                    stalledControlServer.stop()
                }

                let respondingControlServer = TerminalControlServer(
                    socketPath: respondingPaths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.lane.responding.test")
                ) { _ in TerminalControlResponse(ok: true, message: "Sent input.") }
                try respondingControlServer.start()
                defer { respondingControlServer.stop() }

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "control-lane-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")

                let stalledClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { stalledClient.cancel() }
                let stalledFinished = expectation(description: "The stalled terminal control eventually returns.")
                DispatchQueue.global().async {
                    _ = try? stalledClient.send(
                        SpacesDeviceAPIRequest(
                            command: .terminalControl(
                                SpacesDeviceTerminalControlRequest(
                                    action: .send, sessionID: stalledSessionID, clientID: "client-control-lane", text: "ls")),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    stalledFinished.fulfill()
                }
                XCTAssertEqual(stalledRequestArrived.wait(timeout: .now() + 5), .success, "The terminal control must reach the stalled session.")

                let typingClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5)
                let startedAt = Date()
                let response = try typingClient.request(
                    SpacesDeviceAPIRequest(
                        command: .terminalControl(
                            SpacesDeviceTerminalControlRequest(
                                action: .send, sessionID: respondingSessionID, clientID: "client-control-lane", text: "x")),
                        authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(response.ok, response.message)
                XCTAssertLessThan(elapsed, 1.5, "A keystroke for one session must not wait behind another session's stalled control.")

                releaseStalledRequest.signal()
                wait(for: [stalledFinished], timeout: 10)
            }
        }

        /// Lanes are retained per outstanding request and dropped at zero, so nothing accumulates for the
        /// sessions a long-lived daemon has served and forgotten — including the ones that ended without
        /// the daemon ever being told.
        func testAControlLaneIsDroppedOnceItsRequestsFinish() throws {
            try withTemporaryProfile {
                let sessionID = "session-lane-lifecycle-\(UUID().uuidString)"
                let paths = try seedRunningSession(sessionID: sessionID)

                let requestArrived = DispatchSemaphore(value: 0)
                let releaseRequest = DispatchSemaphore(value: 0)
                let controlServer = TerminalControlServer(
                    socketPath: paths.controlSocketPath, queue: DispatchQueue(label: "spaces.device.api.lane.lifecycle.test")
                ) { _ in
                    requestArrived.signal()
                    releaseRequest.wait()
                    return TerminalControlResponse(ok: true, message: "Sent input.")
                }
                try controlServer.start()
                defer {
                    releaseRequest.signal()
                    controlServer.stop()
                }

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                XCTAssertEqual(server.terminalControlLaneCountForTesting, 0, "A server that has answered nothing holds no lanes.")

                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "control-lane-lifecycle-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let client = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { client.cancel() }
                let finished = expectation(description: "The terminal control eventually returns.")
                DispatchQueue.global().async {
                    _ = try? client.send(
                        SpacesDeviceAPIRequest(
                            command: .terminalControl(
                                SpacesDeviceTerminalControlRequest(action: .send, sessionID: sessionID, clientID: "client-control-lane", text: "ls")),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    finished.fulfill()
                }
                XCTAssertEqual(requestArrived.wait(timeout: .now() + 5), .success, "The terminal control must reach the session.")
                XCTAssertEqual(server.terminalControlLaneCountForTesting, 1, "The session being served holds exactly one lane.")

                releaseRequest.signal()
                wait(for: [finished], timeout: 10)

                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, server.terminalControlLaneCountForTesting != 0 { Thread.sleep(forTimeInterval: 0.02) }
                XCTAssertEqual(server.terminalControlLaneCountForTesting, 0, "A lane must not outlive the requests that opened it.")
            }
        }

        /// The other half of the false-banner mechanism: the corroboration `.ping` used to be answered
        /// inline on the shared `spaces.device.api` queue, behind the inline `.overview` work that
        /// dominates that queue's busy time on a loaded daemon. A daemon busy enough to time a keystroke
        /// out is exactly the daemon whose inline backlog delayed the probe, so the probe failed precisely
        /// when it was needed and the pane raised a connection-lost banner over a healthy link.
        func testASlowInlineOverviewDoesNotDelayAPingOnAnotherConnection() throws {
            try withTemporaryProfile {
                let overviewRequestArrived = DispatchSemaphore(value: 0)
                let releaseOverviewRequest = DispatchSemaphore(value: 0)
                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                    overviewLoaderForTesting: { _ in
                        overviewRequestArrived.signal()
                        releaseOverviewRequest.wait()
                        throw NSError(domain: "TerminalControlQueueServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "overview released"])
                    })
                try server.start()
                defer {
                    releaseOverviewRequest.signal()
                    server.stop()
                }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "inline-overview-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let overviewClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { overviewClient.cancel() }
                let overviewFinished = expectation(description: "The stalled overview eventually returns.")
                DispatchQueue.global().async {
                    _ = try? overviewClient.send(SpacesDeviceAPIRequest(command: .overview, authToken: pairingStore.authToken, clientApp: clientApp))
                    overviewFinished.fulfill()
                }
                XCTAssertEqual(overviewRequestArrived.wait(timeout: .now() + 5), .success, "The overview must reach the stalled loader.")

                let probeClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 2)
                let startedAt = Date()
                let pong = try probeClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(pong.ok, pong.message)
                XCTAssertEqual(pong.message, "pong")
                XCTAssertLessThan(elapsed, 1.5, "A ping must not wait behind inline overview work on the shared request queue.")

                releaseOverviewRequest.signal()
                wait(for: [overviewFinished], timeout: 10)
            }
        }

        /// A pong still means this daemon decoded the request and composed the answer, which is the whole
        /// basis for treating a missed probe as conclusive. Moving the answer off the shared queue must not
        /// have turned it into a bare TCP handshake: an unauthorized ping is still rejected.
        func testAPingIsStillAuthorized() throws {
            try withTemporaryProfile {
                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "ping-auth-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")

                let client = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5)
                let rejected = try client.request(SpacesDeviceAPIRequest(command: .ping, authToken: "wrong-token", clientApp: clientApp))
                XCTAssertFalse(rejected.ok)
                XCTAssertEqual(rejected.errorCode, .unauthorized)
            }
        }

        /// A third, non-engine shape that also runs seconds or longer: `.runWorkspaceSetup` executes the
        /// user's setup script to completion in the foreground (`WorkspaceOrchestrator+Setup.swift`,
        /// `waitUntilExit`). It diverts to its own serial `workspaceSetupQueue`, separate from the
        /// teardown family's `workspaceTeardownQueue` (see the next test), for the same reason either
        /// diverts at all: left inline it would hold up every other connection's requests, including the
        /// corroboration `.ping` a client sends after an input-send timeout.
        func testARunningWorkspaceSetupDoesNotDelayAPingOnAnotherConnection() throws {
            try withTemporaryProfile {
                let workspaceID = "workspace-lifecycle-setup-\(UUID().uuidString)"
                let fifoPath = try seedBlockingWorkspaceSetup(workspaceID: workspaceID)
                // Guards the fifo release against a double write: a write that lands after the setup
                // script already read its one line and exited would block forever waiting for a reader
                // that will never come back, hanging the test instead of failing it.
                var fifoReleased = false
                func releaseFIFOOnce() {
                    guard !fifoReleased else { return }
                    fifoReleased = true
                    releaseFIFO(fifoPath)
                }
                // Safety net: if an assertion below throws or fails before the deliberate release runs,
                // this still unblocks the setup script so the background request (and the server) can tear
                // down instead of hanging the test run.
                defer { releaseFIFOOnce() }

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "workspace-lifecycle-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let setupClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { setupClient.cancel() }
                let setupFinished = expectation(description: "The blocked workspace setup eventually returns.")
                DispatchQueue.global().async {
                    _ = try? setupClient.send(
                        SpacesDeviceAPIRequest(
                            command: .runWorkspaceSetup(SpacesDeviceWorkspaceReference(workspaceID: workspaceID)), authToken: pairingStore.authToken,
                            clientApp: clientApp))
                    setupFinished.fulfill()
                }
                try waitUntilWorkspaceSetupIsRunning(workspaceID: workspaceID)

                let probeClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 2)
                let startedAt = Date()
                let pong = try probeClient.request(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(pong.ok, pong.message)
                XCTAssertEqual(pong.message, "pong")
                XCTAssertLessThan(elapsed, 1.5, "A ping must not wait behind a workspace setup script stalled in the workspace-setup queue.")

                releaseFIFOOnce()
                wait(for: [setupFinished], timeout: 10)
            }
        }

        /// Proves the fix for the finding that motivated splitting `workspaceSetupQueue` out of
        /// `workspaceTeardownQueue`: before the split, `.runWorkspaceSetup` shared one serial queue with
        /// `.archiveWorkspace`/`.deleteProject`/`.stopWorkspace`, so a long or hung setup script on one
        /// workspace blocked teardown of every other workspace behind it. This seeds a second, unrelated
        /// workspace with no setup script and archives it while the first workspace's setup is blocked on
        /// the fifo; the archive must complete promptly rather than waiting behind the setup.
        func testAnArchiveOnAnotherWorkspaceDoesNotWaitBehindARunningSetup() throws {
            try withTemporaryProfile {
                let blockedWorkspaceID = "workspace-setup-blocked-\(UUID().uuidString)"
                let fifoPath = try seedBlockingWorkspaceSetup(workspaceID: blockedWorkspaceID)
                // Guards the fifo release against a double write, same as the neighboring test: a write
                // that lands after the setup script already read its one line and exited would block
                // forever waiting for a reader that will never come back, hanging the test instead of
                // failing it.
                var fifoReleased = false
                func releaseFIFOOnce() {
                    guard !fifoReleased else { return }
                    fifoReleased = true
                    releaseFIFO(fifoPath)
                }
                defer { releaseFIFOOnce() }

                let archivableWorkspaceID = "workspace-setup-archive-\(UUID().uuidString)"
                try seedArchivableWorkspace(workspaceID: archivableWorkspaceID)

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "workspace-setup-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let setupClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { setupClient.cancel() }
                let setupFinished = expectation(description: "The blocked workspace setup eventually returns.")
                DispatchQueue.global().async {
                    _ = try? setupClient.send(
                        SpacesDeviceAPIRequest(
                            command: .runWorkspaceSetup(SpacesDeviceWorkspaceReference(workspaceID: blockedWorkspaceID)),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    setupFinished.fulfill()
                }
                try waitUntilWorkspaceSetupIsRunning(workspaceID: blockedWorkspaceID)

                let archiveClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5)
                let startedAt = Date()
                let response = try archiveClient.request(
                    SpacesDeviceAPIRequest(
                        command: .archiveWorkspace(SpacesDeviceWorkspaceArchiveRequest(workspaceID: archivableWorkspaceID)),
                        authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(response.ok, response.message)
                XCTAssertLessThan(
                    elapsed, 1.5, "An archive of a different workspace must not wait behind a workspace setup stalled on another workspace.")

                releaseFIFOOnce()
                wait(for: [setupFinished], timeout: 10)
            }
        }

        /// Proves the fix for the finding that motivated splitting `workspaceStopQueue` out of
        /// `workspaceTeardownQueue`: before the split, `.stopWorkspace` shared one serial queue with
        /// `.archiveWorkspace`/`.deleteProject`, so a hung stop script on one workspace blocked archive or
        /// delete of every other workspace behind it. This seeds a workspace whose stop script blocks on a
        /// fifo, issues `.stopWorkspace` for it, and archives an unrelated second workspace while the first
        /// workspace's stop is blocked; the archive must complete promptly rather than waiting behind the
        /// stop.
        func testAnArchiveOnAnotherWorkspaceDoesNotWaitBehindARunningStop() throws {
            try withTemporaryProfile {
                let blockedWorkspaceID = "workspace-stop-blocked-\(UUID().uuidString)"
                let blockedStopScript = try seedWorkspaceWithBlockingStopScript(workspaceID: blockedWorkspaceID)
                // Guards the fifo release against a double write, same as the neighboring setup test: a
                // write that lands after the stop script already read its one line and exited would block
                // forever waiting for a reader that will never come back, hanging the test instead of
                // failing it.
                var fifoReleased = false
                func releaseFIFOOnce() {
                    guard !fifoReleased else { return }
                    fifoReleased = true
                    releaseFIFO(blockedStopScript.fifoPath)
                }
                defer { releaseFIFOOnce() }

                let archivableWorkspaceID = "workspace-stop-archive-\(UUID().uuidString)"
                try seedArchivableWorkspace(workspaceID: archivableWorkspaceID)

                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore)
                try server.start()
                defer { server.stop() }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "workspace-stop-queue-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos",
                    deviceName: "Mac", appVersion: "1.0")

                let stopClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { stopClient.cancel() }
                let stopFinished = expectation(description: "The blocked workspace stop eventually returns.")
                DispatchQueue.global().async {
                    _ = try? stopClient.send(
                        SpacesDeviceAPIRequest(
                            command: .stopWorkspace(SpacesDeviceWorkspaceLifecycleRequest(workspaceID: blockedWorkspaceID)),
                            authToken: pairingStore.authToken, clientApp: clientApp))
                    stopFinished.fulfill()
                }
                try waitUntilWorkspaceStopScriptIsRunning(markerPath: blockedStopScript.markerPath)

                let archiveClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5)
                let startedAt = Date()
                let response = try archiveClient.request(
                    SpacesDeviceAPIRequest(
                        command: .archiveWorkspace(SpacesDeviceWorkspaceArchiveRequest(workspaceID: archivableWorkspaceID)),
                        authToken: pairingStore.authToken, clientApp: clientApp))
                let elapsed = Date().timeIntervalSince(startedAt)

                XCTAssertTrue(response.ok, response.message)
                XCTAssertLessThan(
                    elapsed, 1.5, "An archive of a different workspace must not wait behind a workspace stop stalled on another workspace.")

                releaseFIFOOnce()
                wait(for: [stopFinished], timeout: 10)
            }
        }

        /// Admission is checked when a request line is read, on that connection's own queue, and the
        /// handler then hops to the shared queue — so a `resetPairingsAndStop()` can land in between and
        /// the request would be served after teardown. `.pair` is the sharpest case because it skips
        /// authorization by design: served late, it mints a token into the pairings file the reset just
        /// emptied, leaving a credential for a daemon the user believed they had unpaired.
        ///
        /// This pins the user-visible invariant — no token survives a reset — across a genuine reset landing
        /// while a pairing request is in flight on a live connection. It does not pin WHICH guard refused
        /// it: the moment a connection's read loop decodes a line and enqueues its dispatch is not
        /// observable through these seams, so whether the reset beat that decode (the read loop's own
        /// admission check refuses) or followed it (`admitOnQueue` on the shared queue refuses) cannot be
        /// chosen from a test — removing `admitOnQueue` leaves this test passing, because the read loop
        /// usually wins the race. The recheck itself is pinned separately and deterministically by
        /// `testAdmissionIsRefusedOnTheDeviceAPIQueueOnceTheServerStops`.
        func testAPairThatReachesTheQueueAfterAResetIssuesNoToken() throws {
            try withTemporaryProfile {
                let overviewRequestArrived = DispatchSemaphore(value: 0)
                let releaseOverviewRequest = DispatchSemaphore(value: 0)
                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = try SpacesDevicePairingStore()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                    overviewLoaderForTesting: { _ in
                        overviewRequestArrived.signal()
                        releaseOverviewRequest.wait()
                        throw NSError(domain: "TerminalControlQueueServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "overview released"])
                    })
                try server.start()
                defer {
                    releaseOverviewRequest.signal()
                    server.stop()
                }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)

                // The already-paired client that will hold the shared queue.
                let holderApp = SpacesDeviceClientApp(
                    installationID: "reset-race-holder", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")
                let holderWindow = server.openPairingWindow(hosts: ["127.0.0.1"], name: "holder")
                let holderPairClient = try SpacesDeviceAPIRequestClient(resolver: resolver, timeoutSeconds: 5)
                let holderPaired = try holderPairClient.request(
                    SpacesDeviceAPIRequest(
                        command: .pair(
                            SpacesDevicePairRequest(
                                pairingCode: holderWindow.code, pairingNonce: holderWindow.nonce, clientProtocolVersion: SpacesWireProtocol.version)),
                        clientApp: holderApp))
                XCTAssertTrue(holderPaired.ok, holderPaired.message)
                guard case .issuedAuthToken(let holderToken)? = holderPaired.result else { return XCTFail("Pairing issued no token.") }

                let holderClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { holderClient.cancel() }
                let overviewFinished = expectation(description: "The stalled overview eventually returns.")
                DispatchQueue.global().async {
                    _ = try? holderClient.send(SpacesDeviceAPIRequest(command: .overview, authToken: holderToken.authToken, clientApp: holderApp))
                    overviewFinished.fulfill()
                }
                XCTAssertEqual(overviewRequestArrived.wait(timeout: .now() + 5), .success, "The overview must reach the stalled loader.")

                // A window the racing client could legitimately pair against, opened while the daemon is
                // still up: without the recheck it is the reset, not the window, that should have stopped
                // the pairing.
                let racingWindow = server.openPairingWindow(hosts: ["127.0.0.1"], name: "racing")
                let racingApp = SpacesDeviceClientApp(
                    installationID: "reset-race-racer", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "ios", deviceName: "iPhone",
                    appVersion: "1.0")

                // Established, and its read loop proven live, BEFORE the reset is enqueued: the `.ping` is
                // answered on this connection's own queue, clear of the blocked shared queue, so it takes
                // the TLS handshake out of the window the pairing request has to arrive in. It carries the
                // holder's credentials because a rejected request is answered and then the connection is
                // cancelled (`finishRequest`), which would kill the connection the pair still has to travel
                // on. Identity is per request, not per connection, so borrowing it here proves liveness
                // without pairing the racing client.
                let racingClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { racingClient.cancel() }
                let racingPong = try racingClient.send(
                    SpacesDeviceAPIRequest(command: .ping, authToken: holderToken.authToken, clientApp: holderApp), timeoutSeconds: 5)
                XCTAssertTrue(racingPong.ok, "The racing connection must still be live when the pair request goes out.")

                // Enqueued on the shared queue while it is blocked, so it runs before anything the racing
                // client has not even sent yet.
                server.queue.async { try? server.resetPairingsAndStop() }
                let pairFinished = expectation(description: "The racing pair request eventually returns.")
                let pairResponse = ResponseBox()
                DispatchQueue.global().async {
                    do {
                        pairResponse.set(
                            try racingClient.send(
                                SpacesDeviceAPIRequest(
                                    command: .pair(
                                        SpacesDevicePairRequest(
                                            pairingCode: racingWindow.code, pairingNonce: racingWindow.nonce,
                                            clientProtocolVersion: SpacesWireProtocol.version)), clientApp: racingApp),
                                // Short, because the expected outcome is a refusal on a connection the
                                // teardown has already cancelled: nothing will answer this one.
                                timeoutSeconds: 3))
                    } catch {}
                    pairFinished.fulfill()
                }

                releaseOverviewRequest.signal()
                wait(for: [overviewFinished, pairFinished], timeout: 15)

                XCTAssertNotEqual(pairResponse.value()?.ok, true, "A pair request must not succeed once the pairings have been reset.")
                XCTAssertEqual(try pairingStore.listDevices(), [], "A reset must leave no pairing behind, including one minted while it ran.")
                if case .issuedAuthToken(let racedToken)? = pairResponse.value()?.result {
                    XCTAssertThrowsError(
                        try pairingStore.authorize(clientApp: racingApp, authToken: racedToken.authToken),
                        "A token issued across a reset must not authorize.")
                }
            }
        }

        /// The recheck the hopped dispatch performs, pinned directly because the interleaving that needs it
        /// cannot be produced from a test (see `testAPairThatReachesTheQueueAfterAResetIssuesNoToken`).
        /// Admission is read on the Device API queue, which is where `stop()` publishes it, so the check
        /// and the work it guards are one critical section rather than a snapshot taken elsewhere.
        func testAdmissionIsRefusedOnTheDeviceAPIQueueOnceTheServerStops() throws {
            try withTemporaryProfile {
                let identity = try controlQueueTestTLSIdentity()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: AlwaysAuthorizedControlQueuePairingStore())
                try server.start()
                defer { server.stop() }

                try server.queue.sync { XCTAssertNoThrow(try server.admitOnQueue(), "A running server admits requests.") }

                server.stop()
                // `stop()` hops onto the Device API queue; this sync drains behind it, so the assertion
                // below reads the state the stop published rather than racing it.
                server.queue.sync {}

                try server.queue.sync {
                    XCTAssertThrowsError(try server.admitOnQueue(), "A stopped server refuses a request that reaches its dispatch point.") { error in
                        XCTAssertEqual(SpacesDeviceAPIServer.errorCode(for: error), .internalError)
                    }
                }
            }
        }

        /// A connection is started before it is registered, so that an accept never waits on the shared
        /// queue's inline work — which means the registration lands on that queue after the connection is
        /// already live, and whatever happened to the connection meanwhile has to win. This drives the
        /// orderable half: a stop that runs between the accept and the registration must leave the
        /// registry empty rather than holding a connection its own sweep already passed over.
        ///
        /// The other half — a connection whose teardown is enqueued BEFORE its registration — cannot be
        /// forced through these seams, because the accept handler enqueues the registration on the very
        /// next statement after starting the connection. That ordering is made harmless structurally
        /// instead (`RequestConnection.didTearDownOnDeviceAPIQueue`), so registration and removal commute.
        func testAConnectionAcceptedAcrossAStopDoesNotLingerInTheRegistry() throws {
            try withTemporaryProfile {
                let overviewRequestArrived = DispatchSemaphore(value: 0)
                let releaseOverviewRequest = DispatchSemaphore(value: 0)
                let identity = try controlQueueTestTLSIdentity()
                let pairingStore = AlwaysAuthorizedControlQueuePairingStore()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: pairingStore,
                    overviewLoaderForTesting: { _ in
                        overviewRequestArrived.signal()
                        releaseOverviewRequest.wait()
                        throw NSError(domain: "TerminalControlQueueServerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "overview released"])
                    })
                try server.start()
                defer {
                    releaseOverviewRequest.signal()
                    server.stop()
                }
                let resolver = SpacesDeviceEndpointResolver(
                    hosts: ["127.0.0.1"], port: server.listeningPort, certificateFingerprint: identity.certificateFingerprint)
                let clientApp = SpacesDeviceClientApp(
                    installationID: "accept-race-test", bundleID: SpacesDeviceFirstPartyPolicy.allowedBundleID, platform: "macos", deviceName: "Mac",
                    appVersion: "1.0")

                let holderClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { holderClient.cancel() }
                let overviewFinished = expectation(description: "The stalled overview eventually returns.")
                DispatchQueue.global().async {
                    _ = try? holderClient.send(SpacesDeviceAPIRequest(command: .overview, authToken: pairingStore.authToken, clientApp: clientApp))
                    overviewFinished.fulfill()
                }
                XCTAssertEqual(overviewRequestArrived.wait(timeout: .now() + 5), .success, "The overview must reach the stalled loader.")

                // Enqueued on the blocked queue, and `stop()` runs inline once it is already there, so the
                // teardown completes in this slot — ahead of the registration the connection below has not
                // enqueued yet. A stop that instead landed at the tail would sweep that registration away
                // itself, and the guard under test would never be what kept the registry empty.
                server.queue.async { server.stop() }

                // Accepted while the listener is still live and the shared queue is blocked, so its
                // registration is queued behind the stop. The `.ping` proves the connection is genuinely
                // up: it is answered on the connection's own queue, clear of the blocked shared queue.
                let lateClient = try SpacesDeviceAPIRequestSessionClient(resolver: resolver)
                defer { lateClient.cancel() }
                let pong = try lateClient.send(SpacesDeviceAPIRequest(command: .ping, authToken: pairingStore.authToken, clientApp: clientApp))
                XCTAssertEqual(pong.message, "pong")

                releaseOverviewRequest.signal()
                wait(for: [overviewFinished], timeout: 15)

                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline, server.requestConnectionCountForTesting != 0 { Thread.sleep(forTimeInterval: 0.02) }
                XCTAssertEqual(server.requestConnectionCountForTesting, 0, "A stopped server must hold no request connections.")
            }
        }

        /// The listener runs on a queue of its own, so its state callbacks are not serialized against
        /// `stopOnQueue`. They therefore publish no lifecycle state themselves: `start` publishes the
        /// running flags on the Device API queue once its wait succeeds, and the callbacks that do have to
        /// publish (`.failed`, `.cancelled`, `.waiting`) hop there under a listener-identity guard.
        ///
        /// What is pinnable is that publication, in both directions, read on the queue that owns it: a
        /// started server reports running with a real port and admits requests, and a stopped one reports
        /// not running — the verdict the supervisor's health check rebuilds on — and refuses them, with no
        /// listener callback needed to make either true. The interleaving the guard exists for, a `.ready`
        /// already executing on the listener queue when a stop lands, cannot be produced through these
        /// seams: nothing can hold an `NWListener` callback mid-flight. That half is argued at the handler.
        func testListenerLifecycleFlagsArePublishedOnTheDeviceAPIQueue() throws {
            try withTemporaryProfile {
                let identity = try controlQueueTestTLSIdentity()
                let server = SpacesDeviceAPIServer(
                    host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: AlwaysAuthorizedControlQueuePairingStore())
                try server.start()
                defer { server.stop() }

                XCTAssertTrue(server.isRunning, "A started listener reports running by the time `start` returns.")
                XCTAssertGreaterThan(server.listeningPort, 0, "A started listener publishes the port it took.")
                try server.queue.sync { XCTAssertNoThrow(try server.admitOnQueue(), "A started server admits requests.") }

                server.stop()
                // `stop()` hops onto the Device API queue; this sync drains behind it, so the assertions
                // below read the state the stop published rather than racing it.
                server.queue.sync {}

                XCTAssertFalse(server.isRunning, "A stopped server reports not running.")
                try server.queue.sync { XCTAssertThrowsError(try server.admitOnQueue(), "A stopped server refuses requests.") }
            }
        }

        /// The smallest payload a live core could export: the test only needs the read to be blocking and
        /// to answer eventually, not to carry a particular frame.
        private func liveStatePayload(sessionID: String) throws -> GhosttyRemoteSessionStatePayload {
            let snapshot = GhosttyTerminalSnapshot(
                columns: 1, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0,
                cells: [GhosttyTerminalSnapshot.Cell(codepoint: 32, foregroundRGB: 0xFFFFFF, backgroundRGB: 0, flags: 0)])
            let frame = GhosttyRenderFrame(sessionRevision: 1, ownerEpoch: 1, snapshot: snapshot)
            return GhosttyRemoteSessionStatePayload(
                sessionID: sessionID, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-08-16T00:00:01Z", sessionStateRevision: 1,
                sessionStateFlags: nil, screenStateRevision: 1, runtimeState: nil, attachmentSnapshot: nil, title: "zsh", workingDirectory: "/tmp",
                outputByteCount: nil, renderUpdate: try GhosttyRenderUpdateBinaryCodec.encode(.full(frame)))
        }

        private func seedRunningSession(sessionID: String) throws -> TerminalSessionPaths {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            try paths.ensureDirectories()
            try TerminalSessionPersistence.writeLaunchConfiguration(
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: "zsh", workingDirectory: "/tmp", shell: "/bin/zsh", command: nil,
                    createdAt: "2026-08-16T00:00:00Z", workspaceID: "workspace-1", kind: .shell), paths: paths)
            try TerminalSessionPersistence.writeRuntimeState(
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: Int32(ProcessInfo.processInfo.processIdentifier), childPID: 123,
                    state: .running, updatedAt: "2026-08-16T00:00:01Z"), paths: paths)
            return paths
        }

        /// Seeds a project and workspace whose setup script blocks reading one line from a fresh named
        /// pipe, and returns that pipe's path. `resolveWorkspace` only reads the database, so a plain
        /// directory on disk (no git repo) is enough for the workspace's worktree — `runWorkspaceSetup`
        /// only needs it to exist as the script's working directory.
        private func seedBlockingWorkspaceSetup(workspaceID: String) throws -> String {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectDir = root.appendingPathComponent("project", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            let fifoPath = root.appendingPathComponent("setup.fifo").path
            guard mkfifo(fifoPath, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            try store.upsert(
                project: ProjectRecord(
                    id: "project-\(workspaceID)", name: "Lifecycle Setup", dir: projectDir.path, isGitRepo: false, defaultBranch: nil,
                    setupScript: "read line < '\(fifoPath)'", stopScript: nil, ports: [], processes: [], browserSessions: []))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: workspaceID, projectID: "project-\(workspaceID)", dir: workspaceDir.path, dirname: nil, branch: "feature", isDefault: true,
                    isRunning: false, lastLaunchedAt: nil))
            return fifoPath
        }

        /// A blocking stop script's fifo (mirrors `seedBlockingWorkspaceSetup`'s pipe) and the marker file
        /// it touches immediately before parking on that fifo, so a poller can tell the script is actually
        /// running rather than merely that the stop request has been sent.
        private struct BlockingStopScript {
            let fifoPath: String
            let markerPath: String
        }

        /// Seeds a project and workspace whose stop script touches a marker file and then blocks reading
        /// one line from a fresh named pipe, mirroring `seedBlockingWorkspaceSetup` for `stopScript`
        /// instead of `setupScript`. Unlike setup, a stop script's progress has no persisted store state to
        /// poll (`workspaceSetupState` is setup-only), so the marker file stands in for it.
        private func seedWorkspaceWithBlockingStopScript(workspaceID: String) throws -> BlockingStopScript {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectDir = root.appendingPathComponent("project", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
            let fifoPath = root.appendingPathComponent("stop.fifo").path
            let markerPath = root.appendingPathComponent("stop.running").path
            guard mkfifo(fifoPath, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            try store.upsert(
                project: ProjectRecord(
                    id: "project-\(workspaceID)", name: "Lifecycle Stop", dir: projectDir.path, isGitRepo: false, defaultBranch: nil,
                    setupScript: nil, stopScript: "touch '\(markerPath)' && read line < '\(fifoPath)'", ports: [], processes: [], browserSessions: [])
            )
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: workspaceID, projectID: "project-\(workspaceID)", dir: workspaceDir.path, dirname: nil, branch: "feature", isDefault: true,
                    isRunning: false, lastLaunchedAt: nil))
            return BlockingStopScript(fifoPath: fifoPath, markerPath: markerPath)
        }

        /// Seeds a second project and workspace with no setup script, for the archive-does-not-wait test.
        /// `isDefault: false` because `archiveWorkspace` rejects a default workspace; a plain, non-git
        /// directory is enough for the same reason it is enough in `seedBlockingWorkspaceSetup` — the
        /// archive handler only needs the workspace's worktree to resolve and, since the project is not a
        /// git repo, never touches git itself.
        private func seedArchivableWorkspace(workspaceID: String) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let projectDir = root.appendingPathComponent("project", isDirectory: true)
            let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            try store.upsert(
                project: ProjectRecord(
                    id: "project-\(workspaceID)", name: "Archivable", dir: projectDir.path, isGitRepo: false, defaultBranch: nil, setupScript: nil,
                    stopScript: nil, ports: [], processes: [], browserSessions: []))
            try store.upsert(
                workspace: WorkspaceRecord(
                    id: workspaceID, projectID: "project-\(workspaceID)", dir: workspaceDir.path, dirname: nil, branch: "feature", isDefault: false,
                    isRunning: false, lastLaunchedAt: nil))
        }

        /// Polls the store rather than the fifo: the goal is to know the setup request has actually reached
        /// the workspace-setup queue and started running the script, not merely that the background send
        /// has been issued, so the corroboration ping (or, in the archive test, the archive request) that
        /// follows is timed against a genuine stall.
        private func waitUntilWorkspaceSetupIsRunning(workspaceID: String, timeout: TimeInterval = 5) throws {
            let deadline = Date().addingTimeInterval(timeout)
            let store = try SQLiteStore(path: DatabaseLocator.defaultPath())
            while Date() < deadline {
                if try store.workspaceSetupState(workspaceID: workspaceID)?.status == .running { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTFail("Workspace setup never reached the running state.")
        }

        /// Polls for the marker file a blocking stop script touches immediately before parking on its fifo
        /// (see `seedWorkspaceWithBlockingStopScript`), mirroring `waitUntilWorkspaceSetupIsRunning`'s
        /// intent: the goal is to know the stop script has actually started running, not merely that the
        /// background `.stopWorkspace` send has been issued, so the archive that follows is timed against a
        /// genuine stall.
        private func waitUntilWorkspaceStopScriptIsRunning(markerPath: String, timeout: TimeInterval = 5) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: markerPath) { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTFail("Workspace stop script never reached the running state.")
        }

        /// Unblocks a setup script parked on `read line < <fifoPath>` by writing one line to the pipe.
        /// Opening a fifo for writing blocks until a reader is attached; that pairs naturally with the
        /// script's blocking read whichever of the two happens first, so callers do not have to sequence
        /// this against the script's own progress.
        private func releaseFIFO(_ path: String) {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            handle.write(Data("go\n".utf8))
        }

        private func withTemporaryProfile(_ body: () throws -> Void) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let originalDatabasePath = ProcessInfo.processInfo.environment[SpacesProfile.databasePathEnvironmentVariable]
            let originalRuntimePath = ProcessInfo.processInfo.environment[SpacesProfile.runtimeDirectoryEnvironmentVariable]
            setenv(SpacesProfile.databasePathEnvironmentVariable, root.appendingPathComponent("spaces.db").path, 1)
            unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
            defer {
                if let originalDatabasePath {
                    setenv(SpacesProfile.databasePathEnvironmentVariable, originalDatabasePath, 1)
                } else {
                    unsetenv(SpacesProfile.databasePathEnvironmentVariable)
                }
                if let originalRuntimePath {
                    setenv(SpacesProfile.runtimeDirectoryEnvironmentVariable, originalRuntimePath, 1)
                } else {
                    unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
                }
                try? FileManager.default.removeItem(at: root)
            }
            try body()
        }
    }

    private let controlQueueTestTLSRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "spaces-control-queue-tests-tls-\(UUID().uuidString)", isDirectory: true)

    /// One pinned-TLS identity per test process: generation is expensive and every server/client pair
    /// only needs a stable certificate to pin.
    private func controlQueueTestTLSIdentity() throws -> TerminalServiceTLSIdentity {
        try TerminalServiceTLSIdentityStore.loadOrCreate(root: controlQueueTestTLSRoot)
    }

    /// Carries one response out of a background send, guarded because the sending thread writes it and
    /// the test thread reads it after the expectation settles.
    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response: SpacesDeviceAPIResponse?

        func set(_ response: SpacesDeviceAPIResponse) {
            lock.lock()
            self.response = response
            lock.unlock()
        }

        func value() -> SpacesDeviceAPIResponse? {
            lock.lock()
            defer { lock.unlock() }
            return response
        }
    }

    private final class AlwaysAuthorizedControlQueuePairingStore: SpacesDevicePairingStoreProtocol {
        let authToken = "valid-token"

        func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { authToken }
        func listDevices() throws -> [SpacesDevicePairedClient] { [] }
        func revoke(installationID _: String) throws {}
        func removeAll() throws {}
        func authorize(clientApp: SpacesDeviceClientApp?, authToken: String?) throws {
            guard clientApp != nil, authToken == self.authToken else {
                throw NSError(domain: "SpacesDeviceAPIServer", code: 401, userInfo: [NSLocalizedDescriptionKey: "Invalid device auth token."])
            }
        }
        func validate(clientApp _: SpacesDeviceClientApp) throws {}
    }
#endif
