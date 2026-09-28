import AppKit
import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

@testable import spacesdeviceapi
@testable import spacesui
@testable import workspacecore

extension ProcessProfileEnvironmentSuites {
    /// The launch surfaces of the restore offer: the offer view's layout under a record of any size, and
    /// the one wait the setup flow's steps share.
    ///
    /// Builds a real `AppKitController` the way `PanelReplacementHoldTests` does (a fabricated
    /// lease/profile pointing at a throwaway directory, so the suite never touches real profile state).
    /// Nests under `ProcessProfileEnvironmentSuites` because it mutates the process-global
    /// `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR`.
    @MainActor @Suite final class SessionRestoreLaunchStepTests {
        private let root: URL
        private let originalDatabasePath: String?
        private let originalRuntimeDirectory: String?

        init() throws {
            originalDatabasePath = ProcessInfo.processInfo.environment["SPACES_DB_PATH"]
            originalRuntimeDirectory = ProcessInfo.processInfo.environment["SPACES_RUNTIME_DIR"]
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            setenv("SPACES_DB_PATH", root.appendingPathComponent("spaces.db").path, 1)
            setenv("SPACES_RUNTIME_DIR", root.appendingPathComponent("runtime", isDirectory: true).path, 1)
        }

        deinit {
            if let originalDatabasePath { setenv("SPACES_DB_PATH", originalDatabasePath, 1) } else { unsetenv("SPACES_DB_PATH") }
            if let originalRuntimeDirectory { setenv("SPACES_RUNTIME_DIR", originalRuntimeDirectory, 1) } else { unsetenv("SPACES_RUNTIME_DIR") }
            try? FileManager.default.removeItem(at: root)
        }

        private func makeController() -> AppKitController {
            let profile = SpacesProfile(
                source: .explicitDatabasePath, databasePath: root.appendingPathComponent("spaces.db").path, rootDirectory: root.path,
                isInstalledProfile: false, runtimeDirectory: root.appendingPathComponent("runtime").path,
                ipcNotificationObject: "com.spaces.test.\(UUID().uuidString)", developmentContext: nil, branchSlug: nil, worktreeHash: nil)
            let owner = SpacesProcessLeaseOwner(
                pid: ProcessInfo.processInfo.processIdentifier, executablePath: "/tmp/spaces-test", profileRoot: root.path, token: UUID().uuidString,
                acquiredAt: "2026-01-01T00:00:00Z")
            let lease = SpacesProcessLease(
                owner: owner, leaseDirectoryPath: root.appendingPathComponent("app-owner-lease").path, metadataPath: "unused", fileManager: .default)
            let context = SpacesAppLaunchContext(profile: profile, appOwnerLease: lease, desktopControlState: .passive(owner))
            return AppKitController(launchContext: context)
        }

        private func offer(rowCount: Int) -> SessionRestoreOffer {
            let summaries = (0..<rowCount).map { index in
                RestorableSessionSummary(
                    sessionID: "s-\(index)", workspaceID: "ws-\(index)", agentKind: .claudeCode, title: "Agent \(index)",
                    workingDirectory: "/repos/workspace-\(index)", hasResumeKey: true, generation: "gen-1")
            }
            let status = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, restorableSessions: summaries)
            return SessionRestoreOffer.make(devices: [.init(deviceID: "local", deviceName: "This Mac", status: status, answeredGeneration: nil)])!
        }

        /// 8 rows across 4 working directories, 3 of them carrying the "New conversation" mark and 5 not:
        /// enough rows that the card's own content exceeds `SessionRestoreOfferView.maximumListHeight`,
        /// while every row shares its group's working directory (so none gets a caption line), giving the
        /// resumable rows only their name label, the fewest-label shape a squashed row was seen with.
        private func mixedOffer() -> SessionRestoreOffer {
            let rows: [(workspaceID: String, hasResumeKey: Bool)] = [
                ("ws-1", true), ("ws-1", true), ("ws-2", true), ("ws-2", true), ("ws-2", false), ("ws-3", true), ("ws-3", false), ("ws-4", false),
            ]
            let summaries = rows.enumerated().map { index, row in
                RestorableSessionSummary(
                    sessionID: "s-\(index)", workspaceID: row.workspaceID, agentKind: .claudeCode, title: "Agent \(index)",
                    workingDirectory: "/repos/\(row.workspaceID)", hasResumeKey: row.hasResumeKey, generation: "gen-1")
            }
            let status = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, restorableSessions: summaries)
            return SessionRestoreOffer.make(devices: [.init(deviceID: "local", deviceName: "This Mac", status: status, answeredGeneration: nil)])!
        }

        private func descendant(of view: NSView, withIdentifier identifier: String) -> NSView? {
            if view.accessibilityIdentifier() == identifier { return view }
            for subview in view.subviews { if let found = descendant(of: subview, withIdentifier: identifier) { return found } }
            return nil
        }

        /// A record can hold far more agents than fit on screen, and both surfaces that host the offer are
        /// fixed height. The list has to absorb that by scrolling: the answer buttons must keep their full
        /// size and stay on screen, or the user is looking at an offer they cannot answer.
        @Test func aLongListScrollsRatherThanSqueezingOutTheAnswerButtons() throws {
            let controller = makeController()
            let view = SessionRestoreOfferView(offer: offer(rowCount: 60), host: controller) { _ in }

            // The sheet's own content size, which is the tighter of the two surfaces (the setup step gets
            // the whole window).
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            container.addSubview(view.view)
            NSLayoutConstraint.activate([
                view.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.view.trailingAnchor.constraint(equalTo: container.trailingAnchor), view.view.topAnchor.constraint(equalTo: container.topAnchor),
                view.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            container.layoutSubtreeIfNeeded()

            for identifier in ["setup-restore-sessions-restore", "setup-restore-sessions-skip"] {
                let button = try #require(descendant(of: view.view, withIdentifier: identifier) as? NSButton, "\(identifier) is in the offer")
                #expect(button.frame.height >= button.fittingSize.height, "\(identifier) keeps its full height")
                #expect(container.bounds.contains(button.convert(button.bounds, to: container)), "\(identifier) is on screen")
            }

            let list = try #require(view.view.firstDescendantScrollView(), "the list is in a scroll view")
            #expect(list.frame.height <= SessionRestoreOfferView.maximumListHeight)
            #expect((list.documentView?.frame.height ?? 0) > list.frame.height, "60 rows are taller than the list, so they scroll")
        }

        /// A device's reason for refusing an answer is a sentence, and a long one (a transport error, a
        /// version mismatch naming both builds) must not cost the user the buttons they need to answer
        /// with: the message wraps above the row instead of growing it sideways.
        @Test func aLongFailureMessageKeepsBothAnswerButtonsOnScreen() throws {
            let controller = makeController()
            let view = SessionRestoreOfferView(offer: offer(rowCount: 3), host: controller) { _ in }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            container.addSubview(view.view)
            NSLayoutConstraint.activate([
                view.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.view.trailingAnchor.constraint(equalTo: container.trailingAnchor), view.view.topAnchor.constraint(equalTo: container.topAnchor),
                view.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            view.showAnswerFailed(String(repeating: "build-box could not be reached. ", count: 20))
            container.layoutSubtreeIfNeeded()

            for identifier in ["setup-restore-sessions-restore", "setup-restore-sessions-skip"] {
                let button = try #require(descendant(of: view.view, withIdentifier: identifier) as? NSButton, "\(identifier) is in the offer")
                #expect(button.frame.width >= button.fittingSize.width, "\(identifier) keeps its full width")
                #expect(container.bounds.contains(button.convert(button.bounds, to: container)), "\(identifier) is on screen")
            }
        }

        /// A short record leaves the list at its own height: nothing is padded out to the cap, so a
        /// one-agent offer reads as a small dialog rather than a mostly empty scroller.
        @Test func aShortListTakesOnlyTheHeightItsRowsNeed() throws {
            let controller = makeController()
            let view = SessionRestoreOfferView(offer: offer(rowCount: 1), host: controller) { _ in }

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            container.addSubview(view.view)
            NSLayoutConstraint.activate([
                view.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.view.trailingAnchor.constraint(equalTo: container.trailingAnchor), view.view.topAnchor.constraint(equalTo: container.topAnchor),
                view.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            container.layoutSubtreeIfNeeded()

            let list = try #require(view.view.firstDescendantScrollView())
            #expect(list.frame.height < SessionRestoreOfferView.maximumListHeight)
            #expect(abs(list.frame.height - (list.documentView?.frame.height ?? 0)) < 1, "the list is exactly as tall as its rows")
        }

        /// Guards the tie between `listFitsItsRows` and a row label's own vertical compression resistance:
        /// at the same priority, once the record's rows outgrow the 240pt cap, Auto Layout could satisfy
        /// the cap by shrinking a row's label to nothing instead of letting the list scroll past it. Every
        /// label must keep at least the height it needs, and the card overall must be at least as tall as
        /// its own fitting size.
        @Test func aRecordTallerThanTheCapScrollsInsteadOfSquashingItsRows() throws {
            let controller = makeController()
            let view = SessionRestoreOfferView(offer: mixedOffer(), host: controller) { _ in }

            let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 560))
            container.addSubview(view.view)
            NSLayoutConstraint.activate([
                view.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.view.trailingAnchor.constraint(equalTo: container.trailingAnchor), view.view.topAnchor.constraint(equalTo: container.topAnchor),
                view.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            container.layoutSubtreeIfNeeded()

            let list = try #require(view.view.firstDescendantScrollView(), "the list is in a scroll view")
            #expect(list.frame.height <= SessionRestoreOfferView.maximumListHeight, "the list itself respects the cap")
            let card = try #require(list.documentView, "the card is the list's document view")
            for label in card.allDescendantTextFields() {
                #expect(
                    label.frame.height >= label.fittingSize.height - 0.5,
                    "\"\(label.stringValue)\" keeps its full height instead of being squashed to fit the cap")
            }
            #expect(card.frame.height >= card.fittingSize.height - 0.5, "the card is not compressed below the height its own rows need")
        }

        // MARK: - One wait per probe

        private func status(restorables: Int) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                restorableSessions: (0..<restorables).map {
                    RestorableSessionSummary(
                        sessionID: "s-\($0)", workspaceID: "ws", agentKind: .claudeCode, title: "Agent", workingDirectory: "/repos/ws",
                        hasResumeKey: true, generation: "gen-1")
                })
        }

        /// The steps run back to back off probes started once. Once a wait has timed out, a later step must
        /// take that as the answer and render immediately: waiting again would spend the whole timeout a
        /// second time on exactly the launch that already proved the daemon is not answering.
        @Test func aSecondStepDoesNotWaitAgainAfterTheProbeTimedOut() async {
            // Answers far later than the deadline below, so a step that returns promptly can only have
            // given up rather than read an answer.
            let probe = Task<[AgentHookStatus]?, Never> {
                try? await Task.sleep(for: .milliseconds(600))
                return []
            }
            let wait = LaunchProbeWait(description: "test probe", deadline: .now.advanced(by: .milliseconds(20)), task: probe)

            let firstStep = await ContinuousClock().measure { _ = await wait.value() }
            var secondStepAnswer: [AgentHookStatus]?
            let secondStep = await ContinuousClock().measure { secondStepAnswer = await wait.value() }

            #expect(firstStep < .milliseconds(400), "the first step gave up on its own deadline rather than waiting for the probe")
            #expect(secondStepAnswer == nil, "a timed-out probe stays timed out")
            #expect(secondStep < .milliseconds(5), "the second step did not wait at all")
            probe.cancel()
        }

        /// The other half of the same rule: an answer is settled once and every later step reads it without
        /// waiting again.
        @Test func aSecondStepReadsTheAnswerTheFirstWaitedFor() async {
            let wait = LaunchProbeWait(
                description: "test probe", deadline: .now.advanced(by: .seconds(5)), task: Task<[AgentHookStatus]?, Never> { [] })

            let first = await wait.value()
            let second = await wait.value()

            #expect(first?.isEmpty == true)
            #expect(second?.isEmpty == true)
        }

        /// The two probes are read by different steps and must fail independently. The hook probe is the
        /// slow one (the daemon resolves the user's login shell `PATH` to answer it) and can outlast the
        /// launch's deadline; when it does, the restore step still has to offer the record the daemon
        /// already handed over, or a crash's worth of agents is silently discarded.
        @Test func aHookProbeThatOutlastsTheDeadlineStillLeavesTheRestoreOfferItsRecord() async {
            let controller = makeController()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
            let hookProbe = Task<[AgentHookStatus]?, Never> {
                try? await Task.sleep(for: .seconds(30))
                return []
            }
            let agentStatus = LaunchProbeWait(description: "hook probe", deadline: deadline, task: hookProbe)
            let daemonStatus = LaunchProbeWait(description: "daemon status probe", deadline: deadline, task: Task { self.status(restorables: 2) })

            // The order the flow runs in: the coding-agents step reads its probe first and waits out the
            // whole launch deadline, then the restore step reads its own.
            let agents = await agentStatus.value()
            let offer = controller.sessionRestore.launchOffer(localDaemonStatus: await daemonStatus.value())

            #expect(agents == nil, "the hook probe never answered")
            #expect(offer?.rowCount == 2, "the restore step still offers what the daemon reported")
            hookProbe.cancel()
        }

        // MARK: - Restore step supersession re-check

        private func remoteOffer(deviceID: String) -> SessionRestoreOffer {
            SessionRestoreOffer.make(devices: [
                .init(deviceID: deviceID, deviceName: "Remote", status: status(restorables: 1), answeredGeneration: nil)
            ])!
        }

        /// The status the step's own offer was built from can already be stale by the time the step
        /// appears (an earlier step held the launch first, and another client answered the record, or an
        /// automation's catch-up run dropped its agent, in the meantime). The `databaseDidChange` observer
        /// alone only reacts to a notice that arrives after the step is up, so a stale offer with no later
        /// notice would sit blocking the workspace UI forever. `showRestoreSessionsStep` runs one re-check
        /// immediately, so this one needs no notification at all to close.
        @Test func showingTheStepReChecksImmediatelyWithNoNotificationNeeded() async throws {
            let controller = makeController()
            let flow = SetupFlowController(host: controller, database: try? controller.clientDatabase(), sessionRestore: controller.sessionRestore)
            var completed = false
            flow.onComplete = { completed = true }
            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in self.status(restorables: 0) }

            flow.showRestoreSessionsStep(offer: offer(rowCount: 1))

            // The immediate re-check runs on its own task, landing at some point after this call returns.
            // Poll for it rather than assuming a fixed delay, bounded so a genuine regression fails fast
            // instead of hanging.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !completed { await Task.yield() }

            #expect(completed, "the step's own initial re-check catches an offer already stale by the time it appears")
        }

        /// A probe that could not reach the device is not evidence anyone has settled the offer, so the
        /// step must stay up rather than close on a read it cannot trust.
        @Test func aNilStatusDuringRecheckKeepsTheRestoreStepUp() async throws {
            let controller = makeController()
            let flow = SetupFlowController(host: controller, database: try? controller.clientDatabase(), sessionRestore: controller.sessionRestore)
            var completed = false
            flow.onComplete = { completed = true }
            flow.showRestoreSessionsStep(offer: offer(rowCount: 1))
            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in nil }

            await flow.recheckRestoreOfferForSupersession()

            #expect(!completed, "a failed probe keeps the step up rather than reading it as an answer")
        }

        /// Every device the step is asking about has settled the record some other way (another client
        /// answered it), so the step finishes silently, exactly like the sheet's own supersession check,
        /// and without going through `SessionRestoreController.answer`, nothing is recorded as answered.
        @Test func aNoRecordStatusDuringRecheckFinishesTheStepWithNoAnsweredGenerationRecorded() async throws {
            let controller = makeController()
            let flow = SetupFlowController(host: controller, database: try? controller.clientDatabase(), sessionRestore: controller.sessionRestore)
            var completed = false
            flow.onComplete = { completed = true }
            flow.showRestoreSessionsStep(offer: offer(rowCount: 1))
            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in self.status(restorables: 0) }

            await flow.recheckRestoreOfferForSupersession()

            #expect(completed, "every device named in the offer has moved on, so the step closes silently")
            #expect(
                try controller.clientDatabase().setting(key: ClientSettingsKey.sessionRestoreAnsweredGenerations) == nil,
                "the re-check settles the step without itself answering the offer")
        }

        /// The step's own answer clears the record too, so a status arriving mid-answer reading "no
        /// record" must not race it: finishing here would drop the pane retargeting the answer still owes
        /// before `onComplete`. Pairs the offer's device with a listener that accepts the TCP connection
        /// but never completes the TLS handshake, so `answer()`'s own network call (on its detached task)
        /// stays genuinely in flight for as long as the test needs to make its assertion, not a timing
        /// assumption. The call's own eventual failure is never awaited: like
        /// `DeviceTerminalSessionStateModelConnectTests`, the connect is left to fail on its own real
        /// timeout in the background rather than the test paying for it, since nothing here depends on how
        /// `answer()` finishes.
        @Test func aNoRecordStatusWhileAnsweringDoesNotEndTheStep() async throws {
            let controller = makeController()
            let listener = try StallingTLSHandshakeListener()
            defer { listener.close() }
            let deviceID = "remote-stalling-\(UUID().uuidString)"
            try controller.clientDatabase().upsert(
                device: SpacesPairedDeviceRecord(
                    id: deviceID, name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: listener.port,
                    certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-01-01T00:00:00Z",
                    updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: "2026-01-01T00:00:00Z"))
            let offer = remoteOffer(deviceID: deviceID)
            let flow = SetupFlowController(host: controller, database: try? controller.clientDatabase(), sessionRestore: controller.sessionRestore)
            var completed = false
            flow.onComplete = { completed = true }
            // Still there (matches the offer's own generation) until `answer()` is confirmed in flight
            // below: `showRestoreSessionsStep` fires its own immediate re-check, and a "no record" status
            // in place this early would let that re-check close the step before this scenario is even set
            // up, rather than exercising the race this test is for.
            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in self.status(restorables: 1) }
            flow.showRestoreSessionsStep(offer: offer)

            Task { await controller.sessionRestore.answer(.skip, offer: offer, panePlacement: .persistedLayouts) }
            // Waits only until `answer()` has set its own in-flight marker (a single synchronous line at
            // the top of the call), never a fixed delay: by then it is blocked on the stalling connect and
            // will stay there until the listener closes.
            while !controller.sessionRestore.isAnswering { await Task.yield() }

            // Only now does the override report "no record": the same status answers both `answer()`'s own
            // reachability check and this test's later re-check, which must not act on it while `answer()`
            // is still working the very offer it names.
            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in self.status(restorables: 0) }

            await flow.recheckRestoreOfferForSupersession()
            #expect(!completed, "the step must not finish while its own offer is still being answered")
        }

        /// A lost reply can report an answer as failed even after the daemon cleared the record it named:
        /// `recheckRestoreOfferForSupersession` bails while `isAnswering`, so nothing re-reads status once
        /// the failed answer settles unless the answer path itself asks again. A closed port fails the
        /// answer's own restore call only after the command's full network timeout (a `.waiting` `NWConnection`
        /// does not treat a refused connect as terminal), so this pairs the offer's device with a real
        /// listening server whose certificate does not match the pin: the handshake rejects it immediately,
        /// standing in for a reply lost in transport, while the probe override reports "no record" throughout,
        /// standing in for the daemon having already cleared it.
        @Test func aFailedAnswerReChecksAndCanCloseTheStep() async throws {
            let controller = makeController()
            let identity = try TerminalServiceTLSIdentityStore.loadOrCreate(root: root.appendingPathComponent("tls-identity", isDirectory: true))
            let server = SpacesDeviceAPIServer(
                host: "127.0.0.1", port: 0, identity: identity, pairingStoreProtocol: AlwaysAuthorizedOfferPairingStore())
            try server.start()
            defer { server.stop() }
            let deviceID = "remote-unreachable-\(UUID().uuidString)"
            try controller.clientDatabase().upsert(
                device: SpacesPairedDeviceRecord(
                    id: deviceID, name: "Remote", platform: "linux", hosts: ["127.0.0.1"], port: server.listeningPort,
                    // Not the server's own fingerprint, so the pinned handshake never gets past it.
                    certificateFingerprint: "SHA256:" + String(repeating: "0", count: 64), createdAt: "2026-01-01T00:00:00Z",
                    updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: "2026-01-01T00:00:00Z"))
            let offer = remoteOffer(deviceID: deviceID)
            let flow = SetupFlowController(host: controller, database: try? controller.clientDatabase(), sessionRestore: controller.sessionRestore)
            var completed = false
            flow.onComplete = { completed = true }
            // Matches the offer's own generation, so the step's initial re-check (fired from
            // `showRestoreSessionsStep`) is a no-op and settles before the override below changes anything,
            // leaving only the post-answer re-check this test is for to explain a later `completed`.
            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in self.status(restorables: 1) }
            flow.showRestoreSessionsStep(offer: offer)
            for _ in 0..<50 { await Task.yield() }

            controller.sessionRestore.daemonStatusProbeOverrideForTesting = { _ in self.status(restorables: 0) }
            let button = try #require(flow.view.firstDescendantButton(identifier: "setup-restore-sessions-restore"))
            button.performClick(nil)

            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !completed { await Task.yield() }

            #expect(completed, "a failed answer re-checks once it settles, so a record cleared underneath it still closes the step")
        }

        /// Leaving the coding-agents step releases it, whichever step follows. The step is usually left for
        /// the restore step, which does not finish the flow, so nothing else would tear it down: the
        /// removed view would sit behind the restore prompt with its agent-config file watcher and its
        /// reload callbacks still live.
        @Test func leavingTheCodingAgentsStepReleasesItEvenWhenTheRestoreStepFollows() throws {
            let controller = makeController()
            let flow = SetupFlowController(host: controller, database: try? controller.clientDatabase(), sessionRestore: controller.sessionRestore)
            flow.showCodingAgentsStep()
            #expect(flow.codingAgents != nil, "the step is on screen")

            // What the user clicks to leave it. Skip and Continue both mean "stop asking about this hook
            // version", and both advance into the restore step rather than finishing the flow.
            let button = try #require(flow.view.firstDescendantButton(identifier: "setup-coding-agents-continue"))
            button.performClick(nil)

            #expect(flow.codingAgents == nil, "the step's view is released as it is left, watcher and callbacks with it")
        }
    }
}

extension NSView {
    /// The first button under this one carrying `identifier`, for tests that click a step's own control
    /// rather than calling the action behind it.
    fileprivate func firstDescendantButton(identifier: String) -> NSButton? {
        if let button = self as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for subview in subviews { if let found = subview.firstDescendantButton(identifier: identifier) { return found } }
        return nil
    }

    /// The first scroll view under this one, for tests that need to reach the offer list.
    fileprivate func firstDescendantScrollView() -> NSScrollView? {
        if let scrollView = self as? NSScrollView { return scrollView }
        for subview in subviews { if let found = subview.firstDescendantScrollView() { return found } }
        return nil
    }

    /// Every text field under this one, for a test that checks no label was squashed below its own
    /// fitting height.
    fileprivate func allDescendantTextFields() -> [NSTextField] {
        subviews.reduce(into: (self as? NSTextField).map { [$0] } ?? []) { fields, subview in fields += subview.allDescendantTextFields() }
    }
}

/// A pairing store that authorizes any request, for a server the pinned-certificate mismatch test never
/// lets a request reach: the handshake itself is what fails, before any pairing check runs.
private final class AlwaysAuthorizedOfferPairingStore: SpacesDevicePairingStoreProtocol {
    func issueToken(for _: SpacesDeviceClientApp, presentedToken _: String?) throws -> String { "always-authorized-token" }
    func listDevices() throws -> [SpacesDevicePairedClient] { [] }
    func revoke(installationID _: String) throws {}
    func removeAll() throws {}
    func authorize(clientApp _: SpacesDeviceClientApp?, authToken _: String?) throws {}
    func validate(clientApp _: SpacesDeviceClientApp) throws {}
}

/// A listener that accepts a TCP connection but never speaks TLS, so a pinned-TLS connect against it
/// genuinely stalls in the handshake instead of failing fast, the same technique
/// `DeviceTerminalSessionStateModelConnectTests` uses to prove a connect never blocks the main actor. Here
/// it proves the opposite: that `SessionRestoreController.answer`'s own network call, dialed from a
/// detached task, is what keeps `isAnswering` true for as long as the test needs, with no timing
/// assumption: a closed port would fail with ECONNREFUSED fast enough to race the assertion instead.
private final class StallingTLSHandshakeListener {
    let port: Int
    private let fd: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var reuseAddress: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0  // Ask the kernel for an ephemeral port.

        let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard listen(socketFD, 1) == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getsocknameResult = withUnsafeMutablePointer(to: &boundAddress) { addressPointer -> Int32 in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in getsockname(socketFD, rebound, &boundAddressLength) }
        }
        guard getsocknameResult == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        fd = socketFD
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    /// Closes the listening socket so a still-stalled connect is reset quickly instead of dragging out
    /// for its full timeout.
    func close() { Darwin.close(fd) }
}
