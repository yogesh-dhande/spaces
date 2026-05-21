#if canImport(UIKit)
    import Darwin
    import Foundation
    import UIKit
    import XCTest
    import spacesterminalcore
    @testable import spacesterminalmobileghostty

    @MainActor
    final class GhosttyMobileAppServiceTests: XCTestCase {
        func testRuntimeConfigProvidesRequiredCallbacks() {
            let runtimeConfig = GhosttyMobileAppService.makeRuntimeConfig()

            XCTAssertNotNil(runtimeConfig.wakeup_cb)
            XCTAssertNotNil(runtimeConfig.action_cb)
            XCTAssertNotNil(runtimeConfig.read_clipboard_cb)
            XCTAssertNotNil(runtimeConfig.confirm_read_clipboard_cb)
            XCTAssertNotNil(runtimeConfig.write_clipboard_cb)
            XCTAssertNotNil(runtimeConfig.close_surface_cb)
            XCTAssertFalse(runtimeConfig.supports_selection_clipboard)
        }

        func testRepairStandardFileDescriptorsRepairsOutputBeforeInstallingKeepAliveStandardInputWhenStdinIsMissing() throws {
            var validDescriptors: Set<Int32> = []
            var duplicateCalls: [(source: Int32, target: Int32)] = []
            var closeCalls: [Int32] = []
            var operations: [String] = []

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    operations.append("createPipe")
                    validDescriptors.insert(5)
                    validDescriptors.insert(6)
                    return (5, 6)
                },
                openReadWriteNull: {
                    operations.append("openNull")
                    validDescriptors.insert(7)
                    return 7
                },
                duplicateDescriptor: { source, target in
                    duplicateCalls.append((source, target))
                    validDescriptors.insert(target)
                    return target
                },
                closeDescriptor: { descriptor in
                    closeCalls.append(descriptor)
                    validDescriptors.remove(descriptor)
                    return 0
                }
            )

            XCTAssertEqual(operations, ["openNull", "createPipe"])
            XCTAssertEqual(duplicateCalls.map(\.source), [7, 7, 5])
            XCTAssertEqual(duplicateCalls.map(\.target), [STDOUT_FILENO, STDERR_FILENO, STDIN_FILENO])
            XCTAssertEqual(closeCalls, [7, 5])
            XCTAssertTrue(validDescriptors.contains(STDIN_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDOUT_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDERR_FILENO))
            XCTAssertEqual(repair.retainedStandardInputWriteDescriptor, 6)
            XCTAssertTrue(validDescriptors.contains(6))
        }

        func testRepairStandardFileDescriptorsReusesStandardInputDescriptorWhenPipeReadEndLandsOnStdin() throws {
            var validDescriptors: Set<Int32> = [STDOUT_FILENO, STDERR_FILENO]
            var duplicateCalls: [(source: Int32, target: Int32)] = []
            var closeCalls: [Int32] = []

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    validDescriptors.insert(STDIN_FILENO)
                    validDescriptors.insert(4)
                    return (STDIN_FILENO, 4)
                },
                duplicateDescriptor: { source, target in
                    duplicateCalls.append((source, target))
                    validDescriptors.insert(target)
                    return target
                },
                closeDescriptor: { descriptor in
                    closeCalls.append(descriptor)
                    validDescriptors.remove(descriptor)
                    return 0
                }
            )

            XCTAssertEqual(duplicateCalls.count, 1)
            XCTAssertEqual(duplicateCalls.first?.source, STDIN_FILENO)
            XCTAssertEqual(duplicateCalls.first?.target, STDIN_FILENO)
            XCTAssertTrue(closeCalls.isEmpty)
            XCTAssertTrue(validDescriptors.contains(STDIN_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDOUT_FILENO))
            XCTAssertTrue(validDescriptors.contains(STDERR_FILENO))
            XCTAssertEqual(repair.retainedStandardInputWriteDescriptor, 4)
            XCTAssertTrue(validDescriptors.contains(4))
        }

        func testRepairStandardFileDescriptorsLeavesValidStandardInputUntouched() throws {
            var validDescriptors: Set<Int32> = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
            var createPipeCallCount = 0
            var openNullCallCount = 0

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    createPipeCallCount += 1
                    return (-1, -1)
                },
                openReadWriteNull: {
                    openNullCallCount += 1
                    return -1
                }
            )

            XCTAssertEqual(createPipeCallCount, 0)
            XCTAssertEqual(openNullCallCount, 0)
            XCTAssertNil(repair.retainedStandardInputWriteDescriptor)
        }

        func testRemoteTerminalHostViewCanMountInWindow() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: nil,
                replayStateKey: "viewer|runtime=0x0|snapshot=0x0|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertNotNil(GhosttyMobileAppService.shared.app)
            XCTAssertTrue(hostView.subviews.contains { $0 is UILabel })
            XCTAssertNotNil(terminalSurfaceLayer(in: hostView))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewDisablesSmartTextFeatures() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)

            XCTAssertEqual(hostView.autocapitalizationType, .none)
            XCTAssertEqual(hostView.autocorrectionType, .no)
            XCTAssertEqual(hostView.spellCheckingType, .no)
            XCTAssertEqual(hostView.smartQuotesType, .no)
            XCTAssertEqual(hostView.smartDashesType, .no)
            XCTAssertEqual(hostView.smartInsertDeleteType, .no)
            XCTAssertEqual(hostView.keyboardType, .asciiCapable)
        }

        func testRemoteTerminalHostViewReplaysSnapshotIntoGhosttySession() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let replayed = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertGreaterThanOrEqual(replayed.columns, 4)
            XCTAssertGreaterThanOrEqual(replayed.rows, 2)
            XCTAssertEqual(replayed.cells.first?.codepoint, UInt32(Character("h").unicodeScalars.first?.value ?? 0))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPrefersSnapshotOverIncrementalOutputOnFreshSession() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                outputData: Data("WRONG".utf8),
                outputEventToken: "event-1",
                outputRepresentsFullHistory: false,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let replayed = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertTrue(GhosttyTerminalSnapshotLayout.plainText(for: replayed).localizedStandardContains("hi"))
            XCTAssertFalse(GhosttyTerminalSnapshotLayout.plainText(for: replayed).localizedStandardContains("WRONG"))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewAppliesIncrementalOutputWhenReplayBaseAlreadyExists() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: GhosttyTerminalSnapshotVTEncoder.encode(sampleSnapshotWithExclamation()),
                outputEventToken: "event-2",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let replayed = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let replayedText = GhosttyTerminalSnapshotLayout.plainText(for: replayed)
            XCTAssertTrue(replayedText.localizedStandardContains("hi!"))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTearsDownSessionWhenRemovedFromWindow() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)

            hostView.removeFromSuperview()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertNil(hostView.capturedSnapshotForTesting())

            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()
            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=2",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)
            XCTAssertNotNil(hostView.capturedSnapshotForTesting())

            window.isHidden = true
        }

        func testRemoteTerminalHostViewCanRecreateSessionsAcrossMultipleMountCycles() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            viewController.view.frame = window.bounds

            for cycle in 1...3 {
                let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
                viewController.view.addSubview(hostView)
                hostView.frame = viewController.view.bounds
                viewController.view.layoutIfNeeded()

                hostView.update(
                    snapshot: sampleSnapshot(),
                    replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=\(cycle)",
                    outputData: nil,
                    outputEventToken: nil,
                    fallbackText: "Waiting for terminal state…"
                )

                RunLoop.main.run(until: Date().addingTimeInterval(0.25))

                XCTAssertTrue(hostView.hasActiveSessionForTesting)
                XCTAssertNotNil(hostView.capturedSnapshotForTesting())

                hostView.removeFromSuperview()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))

                XCTAssertFalse(hostView.hasActiveSessionForTesting)
            }

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPublishesRenderedTextUpdates() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "rendered text published")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("hi") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("hi"))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRepublishesRenderedTextAfterVisibilityToggle() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let replayedRenderedExpectation = expectation(description: "rendered text republished after visibility toggle")
            replayedRenderedExpectation.expectedFulfillmentCount = 1

            var renderedEvents: [String] = []
            hostView.onRenderedTextChanged = { text in
                guard text.localizedStandardContains("hi") else { return }
                renderedEvents.append(text)
                if renderedEvents.count == 1 {
                    initialRenderedExpectation.fulfill()
                } else if renderedEvents.count == 2 {
                    replayedRenderedExpectation.fulfill()
                }
            }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(
                snapshot: nil,
                replayStateKey: "status",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Current owner: Mac"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.setTerminalVisible(true)
            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [replayedRenderedExpectation], timeout: 2)
            XCTAssertEqual(renderedEvents.count, 2)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRepublishesRenderedTextAfterObserverIsReattached() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let republishedRenderedExpectation = expectation(description: "rendered text republished after observer is reattached")

            hostView.onRenderedTextChanged = { text in
                if text.localizedStandardContains("hi") {
                    initialRenderedExpectation.fulfill()
                }
            }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.onRenderedTextChanged = nil
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.onRenderedTextChanged = { text in
                if text.localizedStandardContains("hi!") {
                    republishedRenderedExpectation.fulfill()
                }
            }
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [republishedRenderedExpectation], timeout: 2)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsRenderedTextWhenSurfaceIsHidden() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let clearedRenderedExpectation = expectation(description: "rendered text cleared after hiding the surface")

            var renderedEvents: [String] = []
            hostView.onRenderedTextChanged = { text in
                renderedEvents.append(text)
                if text.localizedStandardContains("hi") {
                    initialRenderedExpectation.fulfill()
                } else if text.isEmpty {
                    clearedRenderedExpectation.fulfill()
                }
            }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(
                snapshot: nil,
                replayStateKey: "status",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Current owner: Mac"
            )

            wait(for: [clearedRenderedExpectation], timeout: 2)
            XCTAssertEqual(renderedEvents.last, "")

            window.isHidden = true
        }

        func testRemoteTerminalHostViewEncodesPreciseScrollMods() {
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed)),
                Int32(0b0000_0101)
            )
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .ended)),
                Int32(0b0000_1000)
            )
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .possible)),
                Int32(0b0000_1010)
            )
        }

        func testRemoteTerminalHostViewCanScrollBackThroughIncrementalOutputHistory() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: scrollbackFixtureOutput(lineCount: 220),
                outputEventToken: "event-scrollback",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)
            XCTAssertTrue(bottomText.localizedStandardContains("SEQ 000219"), bottomText)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0,
                vertical: -2400,
                location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
            )
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertNotEqual(scrolledText, bottomText)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)
            XCTAssertTrue(scrolledText.localizedStandardContains("SEQ 0001"), scrolledText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPreservesIncrementalScrollbackAfterSnapshotAndResizeChurn() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: scrollbackFixtureOutput(lineCount: 220),
                outputEventToken: "event-scrollback",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=6x4|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            hostView.frame = CGRect(x: 0, y: 0, width: 700, height: 420)
            viewController.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0,
                vertical: -2400,
                location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
            )
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)
            XCTAssertTrue(scrolledText.localizedStandardContains("SEQ 0001"), scrolledText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewBootstrapsScrollbackAfterSnapshotOnlyRender() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: scrollbackFixtureOutput(lineCount: 220),
                outputEventToken: "event-bootstrap",
                outputRepresentsFullHistory: true,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)
            XCTAssertTrue(bottomText.localizedStandardContains("SEQ 000219"), bottomText)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0,
                vertical: -2400,
                location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
            )
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertNotEqual(scrolledText, bottomText)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)
            XCTAssertTrue(scrolledText.localizedStandardContains("SEQ 0001"), scrolledText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsStaleReplayBaseBeforeBootstrappingFullHistory() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: promptSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: promptFixtureOutput(),
                outputEventToken: "event-history-bootstrap",
                outputRepresentsFullHistory: true,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let replayed = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let replayedText = GhosttyTerminalSnapshotLayout.plainText(for: replayed)
            XCTAssertFalse(replayedText.localizedStandardContains("hi"), replayedText)
            XCTAssertTrue(replayedText.localizedStandardContains("shell %"), replayedText)
            XCTAssertEqual(replayedText.components(separatedBy: "shell %").count - 1, 1, replayedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewAppliesMultiStepScrollCommand() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: sampleSnapshot(),
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                outputData: scrollbackFixtureOutput(lineCount: 220),
                outputEventToken: "event-command-scroll",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)
            XCTAssertTrue(bottomText.localizedStandardContains("SEQ 000219"), bottomText)

            hostView.applyScrollCommandIfNeeded(
                GhosttyRemoteTerminalScrollCommand(id: "multi-step-scroll", vertical: -2400, repetitions: 24)
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertNotEqual(scrolledText, bottomText)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)
            XCTAssertTrue(scrolledText.localizedStandardContains("SEQ 0001"), scrolledText)

            window.isHidden = true
        }

        private func terminalSurfaceLayer(in hostView: GhosttyRemoteTerminalHostView) -> CALayer? {
            hostView.layer.sublayers?.first(where: { layer in
                abs(layer.frame.width - hostView.bounds.width) < 0.5
                    && abs(layer.frame.height - hostView.bounds.height) < 0.5
            })
        }

        private func sampleSnapshot() -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let characters = Array("hi".unicodeScalars)
            let cells: [GhosttyTerminalSnapshot.Cell] = [
                GhosttyTerminalSnapshot.Cell(codepoint: characters[0].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[1].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                blank,
                blank,
                blank,
                blank,
                blank,
                blank,
            ]

            return GhosttyTerminalSnapshot(
                columns: 4,
                rows: 2,
                cursorColumn: 2,
                cursorRow: 0,
                cursorVisible: true,
                defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26,
                cells: cells
            )
        }

        private func sampleSnapshotWithExclamation() -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let characters = Array("hi!".unicodeScalars)
            let cells: [GhosttyTerminalSnapshot.Cell] = [
                GhosttyTerminalSnapshot.Cell(codepoint: characters[0].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[1].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[2].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                blank,
                blank,
                blank,
                blank,
                blank,
            ]

            return GhosttyTerminalSnapshot(
                columns: 4,
                rows: 2,
                cursorColumn: 3,
                cursorRow: 0,
                cursorVisible: true,
                defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26,
                cells: cells
            )
        }

        private func promptSnapshot() -> GhosttyTerminalSnapshot {
            snapshot(
                columns: 8,
                rows: 2,
                text: "shell % "
            )
        }

        private func scrollbackFixtureOutput(lineCount: Int) -> Data {
            let lines = (0..<lineCount).map { index in "SEQ \(String(format: "%06d", index)) scrollback-line-\(index)" }
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        }

        private func promptFixtureOutput() -> Data { Data("hello\r\nshell % ".utf8) }

        private func snapshotSignature(_ snapshot: GhosttyTerminalSnapshot?) -> String {
            guard let snapshot else { return "nil" }
            let sampleCells = snapshot.cells.prefix(12).map { "\($0.codepoint):\($0.flags)" }.joined(separator: ",")
            return "\(snapshot.columns)x\(snapshot.rows)|cursor=\(snapshot.cursorColumn),\(snapshot.cursorRow)|cells=\(sampleCells)"
        }

        private func snapshot(columns: Int, rows: Int, text: String) -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let scalars = Array(text.unicodeScalars)
            let cellCount = max(columns * rows, scalars.count)
            let cells = (0..<cellCount).map { index in
                guard index < scalars.count else { return blank }
                return GhosttyTerminalSnapshot.Cell(
                    codepoint: scalars[index].value,
                    foregroundRGB: 0xF2F2F2,
                    backgroundRGB: 0x1A1E26,
                    flags: 0
                )
            }

            return GhosttyTerminalSnapshot(
                columns: columns,
                rows: rows,
                cursorColumn: min(scalars.count, columns),
                cursorRow: min(max((max(scalars.count, 1) - 1) / max(columns, 1), 0), max(rows - 1, 0)),
                cursorVisible: true,
                defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26,
                cells: cells
            )
        }
    }

    private extension GhosttyRemoteTerminalHostView {
        func update(
            snapshot: GhosttyTerminalSnapshot?,
            replayStateKey: String,
            outputData: Data?,
            outputEventToken: String?,
            outputRepresentsFullHistory: Bool = false,
            fallbackText: String
        ) {
            let ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?
            if snapshot != nil || outputData != nil {
                let epochID =
                    if outputRepresentsFullHistory {
                        "history|\(outputEventToken ?? replayStateKey)"
                    } else if outputData == nil {
                        "snapshot|\(snapshotSignature(snapshot))"
                    } else {
                        "owner|\(snapshotSignature(snapshot))"
                    }
                let pendingOutput: GhosttyRemoteTerminalOutputBatch?
                if outputRepresentsFullHistory || outputData?.isEmpty != false {
                    pendingOutput = nil
                } else {
                    pendingOutput = GhosttyRemoteTerminalOutputBatch(id: outputEventToken ?? replayStateKey, data: outputData ?? Data())
                }
                ownerEpoch = GhosttyRemoteTerminalOwnerEpoch(
                    id: epochID,
                    bootstrapSnapshot: snapshot,
                    bootstrapOutputData: outputRepresentsFullHistory ? outputData : nil,
                    pendingOutput: pendingOutput
                )
            } else {
                ownerEpoch = nil
            }
            update(ownerEpoch: ownerEpoch, endedRender: nil, fallbackText: fallbackText)
        }

        private func snapshotSignature(_ snapshot: GhosttyTerminalSnapshot?) -> String {
            guard let snapshot else { return "nil" }
            let sampleCells = snapshot.cells.prefix(12).map { "\($0.codepoint):\($0.flags)" }.joined(separator: ",")
            return "\(snapshot.columns)x\(snapshot.rows)|cursor=\(snapshot.cursorColumn),\(snapshot.cursorRow)|cells=\(sampleCells)"
        }
    }
#endif
