import AppKit
import Testing
import spacesdevicecore
import spacesterminalcore

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
}
