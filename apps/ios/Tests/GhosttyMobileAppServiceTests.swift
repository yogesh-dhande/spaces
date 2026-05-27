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

        func testPhoneViewportReportsReadableColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 80,
                rawRows: 24,
                bounds: CGRect(x: 0, y: 0, width: 393, height: 700),
                idiom: .phone
            )

            XCTAssertEqual(viewport.columns, 39)
            XCTAssertEqual(viewport.rows, 24)
        }

        func testPadViewportKeepsGhosttyColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 120,
                rawRows: 40,
                bounds: CGRect(x: 0, y: 0, width: 1024, height: 900),
                idiom: .pad
            )

            XCTAssertEqual(viewport.columns, 120)
            XCTAssertEqual(viewport.rows, 40)
        }

        func testPendingOutputReconciliationDropsBytesAtOrBeforeHistorySeedEnd() {
            let historySeed = GhosttyRemoteTerminalOutputBatch(
                id: "history",
                data: Data("tail-window".utf8),
                outputEndByteOffset: 100
            )
            let pendingOutputs = [
                GhosttyRemoteTerminalOutputBatch(id: "before-tail", data: Data("old".utf8), outputEndByteOffset: 80),
                GhosttyRemoteTerminalOutputBatch(id: "inside-tail", data: Data("tail".utf8), outputEndByteOffset: 98),
                GhosttyRemoteTerminalOutputBatch(id: "after-tail", data: Data("new".utf8), outputEndByteOffset: 103),
            ]

            let reconciled = GhosttyRemoteTerminalOutputBatch.pendingOutputsNotCovered(
                by: historySeed,
                pendingOutputs: pendingOutputs
            )

            XCTAssertEqual(reconciled, [pendingOutputs[2]])
        }

        func testPendingOutputReconciliationKeepsOnlySuffixAfterHistorySeedEnd() {
            let historySeed = GhosttyRemoteTerminalOutputBatch(
                id: "history",
                data: Data("tail-window".utf8),
                outputEndByteOffset: 100
            )
            let pendingOutput = GhosttyRemoteTerminalOutputBatch(
                id: "straddles-end",
                data: Data("abcXYZ".utf8),
                outputEndByteOffset: 103
            )

            let reconciled = GhosttyRemoteTerminalOutputBatch.pendingOutputsNotCovered(
                by: historySeed,
                pendingOutputs: [pendingOutput]
            )

            XCTAssertEqual(
                reconciled,
                [
                    GhosttyRemoteTerminalOutputBatch(
                        id: "straddles-end|after|100",
                        data: Data("XYZ".utf8),
                        outputEndByteOffset: 103
                    )
                ]
            )
        }

        func testAppendingOutputAfterHistorySeedDropsCoveredBatch() {
            let historySeed = GhosttyRemoteTerminalOutputBatch(
                id: "history",
                data: Data("tail-window".utf8),
                outputEndByteOffset: 100
            )
            let existingPending = [
                GhosttyRemoteTerminalOutputBatch(id: "after-seed", data: Data("new".utf8), outputEndByteOffset: 103)
            ]
            let coveredLateBatch = GhosttyRemoteTerminalOutputBatch(
                id: "late-covered",
                data: Data("old".utf8),
                outputEndByteOffset: 98
            )

            let reconciled = GhosttyRemoteTerminalOutputBatch.appendingOutputNotCovered(
                coveredLateBatch,
                to: existingPending,
                by: historySeed
            )

            XCTAssertEqual(reconciled, existingPending)
        }

        func testAppendingOutputAfterAppliedHistorySeedDropsCoveredBatch() {
            let coveredLateBatch = GhosttyRemoteTerminalOutputBatch(
                id: "late-covered",
                data: Data("old".utf8),
                outputEndByteOffset: 98
            )

            let reconciled = GhosttyRemoteTerminalOutputBatch.appendingOutputNotCovered(
                coveredLateBatch,
                to: [],
                byHistorySeedEndOffset: 100
            )

            XCTAssertTrue(reconciled.isEmpty)
        }

        func testAppendingOutputAfterHistorySeedKeepsOnlyUncoveredSuffix() {
            let historySeed = GhosttyRemoteTerminalOutputBatch(
                id: "history",
                data: Data("tail-window".utf8),
                outputEndByteOffset: 100
            )
            let straddlingLateBatch = GhosttyRemoteTerminalOutputBatch(
                id: "late-straddles",
                data: Data("abcXYZ".utf8),
                outputEndByteOffset: 103
            )

            let reconciled = GhosttyRemoteTerminalOutputBatch.appendingOutputNotCovered(
                straddlingLateBatch,
                to: [],
                by: historySeed
            )

            XCTAssertEqual(
                reconciled,
                [
                    GhosttyRemoteTerminalOutputBatch(
                        id: "late-straddles|after|100",
                        data: Data("XYZ".utf8),
                        outputEndByteOffset: 103
                    )
                ]
            )
        }

        func testTouchScrollFingerDownMapsTowardOlderScrollback() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(
                forPanDelta: CGPoint(x: 0, y: 12),
                scaleFactor: 2
            )

            XCTAssertEqual(delta.y, 24)
        }

        func testTouchScrollFingerUpMapsTowardLiveBottom() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(
                forPanDelta: CGPoint(x: 0, y: -12),
                scaleFactor: 2
            )

            XCTAssertEqual(delta.y, -24)
        }

        func testTouchScrollUsesScaleFactorAsPointToPixelConversion() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(
                forPanDelta: CGPoint(x: 4, y: 10),
                scaleFactor: 3
            )

            XCTAssertEqual(delta.x, -12)
            XCTAssertEqual(delta.y, 30)
        }

        func testHighVelocityMomentumProducesBoundedDeltas() {
            let delta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(
                velocity: CGPoint(x: 20_000, y: 20_000),
                elapsed: 1,
                scaleFactor: 3
            )

            XCTAssertEqual(delta.x, -720)
            XCTAssertEqual(delta.y, 720)
        }

        func testResolveResourcesPathUsesBundledGhosttyResources() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundledResources = root.appendingPathComponent("ghostty", isDirectory: true)
            try FileManager.default.createDirectory(at: bundledResources, withIntermediateDirectories: true)

            let resolved = try GhosttyMobileAppService.resolveResourcesPath(
                environment: [:],
                bundleResourceURL: root,
                sourceFilePath: "/unavailable/Sources/spacesterminalmobileghostty/GhosttyMobileAppService.swift"
            )

            XCTAssertEqual(resolved, bundledResources.path)
        }

        func testConfigureGhosttyProcessEnvironmentSetsHomeAndXDGDirectories() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("home", isDirectory: true)
            let support = root.appendingPathComponent("support", isDirectory: true)
            let caches = root.appendingPathComponent("caches", isDirectory: true)
            var environment: [String: (value: String, overwrite: Int32)] = [:]

            try GhosttyMobileAppService.configureGhosttyProcessEnvironment(
                homeDirectory: home,
                applicationSupportDirectory: support,
                cachesDirectory: caches,
                setEnvironment: { name, value, overwrite in
                    environment[name] = (value, overwrite)
                    return 0
                }
            )

            XCTAssertEqual(environment["HOME"]?.value, home.path)
            XCTAssertEqual(environment["HOME"]?.overwrite, 1)
            XCTAssertEqual(environment["SHELL"]?.value, "/bin/sh")
            XCTAssertEqual(environment["XDG_CONFIG_HOME"]?.value, support.appendingPathComponent("ghostty/config", isDirectory: true).path)
            XCTAssertEqual(environment["XDG_STATE_HOME"]?.value, support.appendingPathComponent("ghostty/state", isDirectory: true).path)
            XCTAssertEqual(environment["XDG_CACHE_HOME"]?.value, caches.appendingPathComponent("ghostty/cache", isDirectory: true).path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_CONFIG_HOME"]?.value ?? ""))
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_STATE_HOME"]?.value ?? ""))
            XCTAssertTrue(FileManager.default.fileExists(atPath: environment["XDG_CACHE_HOME"]?.value ?? ""))
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

        func testRepairStandardFileDescriptorsReplacesValidStandardInputWithKeepAlivePipe() throws {
            var validDescriptors: Set<Int32> = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
            var duplicateCalls: [(source: Int32, target: Int32)] = []
            var closeCalls: [Int32] = []
            var openNullCallCount = 0

            let repair = try GhosttyMobileAppService.repairStandardFileDescriptors(
                isDescriptorValid: { validDescriptors.contains($0) },
                createStandardInputPipe: {
                    validDescriptors.insert(5)
                    validDescriptors.insert(6)
                    return (5, 6)
                },
                openReadWriteNull: {
                    openNullCallCount += 1
                    return -1
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

            XCTAssertEqual(duplicateCalls.map(\.source), [5])
            XCTAssertEqual(duplicateCalls.map(\.target), [STDIN_FILENO])
            XCTAssertEqual(closeCalls, [5])
            XCTAssertEqual(openNullCallCount, 0)
            XCTAssertEqual(repair.retainedStandardInputWriteDescriptor, 6)
            XCTAssertTrue(validDescriptors.contains(STDIN_FILENO))
            XCTAssertTrue(validDescriptors.contains(6))
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

        func testRemoteTerminalHostViewSuppressesSystemKeyboardAssistant() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)

            XCTAssertTrue(hostView.inputAssistantIsSuppressedForTesting)
        }

        func testRemoteTerminalAccessoryToolbarKeepsTrailingControlsPinned() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            XCTAssertEqual(accessoryView.intrinsicContentSize.height, 58)
            XCTAssertEqual(accessoryView.frame.height, 58)
            XCTAssertEqual(accessoryView.sizeThatFits(CGSize(width: 320, height: 0)).height, 58)
            XCTAssertTrue(accessoryView.autoresizingMask.contains(.flexibleHeight))

            let labels = hostView.accessoryToolbarButtonAccessibilityLabelsForTesting
            XCTAssertEqual(labels.scrollable, ["tab", "/", "~", "|", "-", "_", "esc", "Control"])
            XCTAssertEqual(labels.pinned, ["Arrow key joystick", "Hide keyboard"])

            let phoneFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .phone)
            XCTAssertGreaterThan(phoneFrames.scrollView.width, 0)
            XCTAssertGreaterThanOrEqual(phoneFrames.joystickButton.minX, phoneFrames.scrollView.maxX + 5.5)
            XCTAssertGreaterThanOrEqual(phoneFrames.keyboardButton.minX, phoneFrames.joystickButton.maxX + 5.5)
            XCTAssertLessThanOrEqual(phoneFrames.keyboardButton.maxX, 312.5)
            XCTAssertEqual(phoneFrames.joystickButton.width, 46, accuracy: 0.5)
            XCTAssertEqual(phoneFrames.keyboardButton.width, 46, accuracy: 0.5)
            let phoneWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .phone)
            for width in phoneWidths.scrollable {
                XCTAssertEqual(width, 50, accuracy: 0.5)
            }

            let padFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .pad)
            XCTAssertGreaterThanOrEqual(padFrames.joystickButton.minX, padFrames.scrollView.maxX + 7.5)
            XCTAssertGreaterThanOrEqual(padFrames.keyboardButton.minX, padFrames.joystickButton.maxX + 7.5)
            XCTAssertLessThanOrEqual(padFrames.keyboardButton.maxX, 308.5)
            XCTAssertEqual(padFrames.joystickButton.width, 56, accuracy: 0.5)
            XCTAssertEqual(padFrames.keyboardButton.width, 56, accuracy: 0.5)
            let padWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .pad)
            for width in padWidths.scrollable {
                XCTAssertEqual(width, 64, accuracy: 0.5)
            }

            hostView.setSoftwareKeyboardVisible(false)
            XCTAssertEqual(hostView.accessoryToolbarButtonAccessibilityLabelsForTesting.pinned, ["Arrow key joystick", "Show keyboard"])
        }

        func testRemoteTerminalAccessoryJoystickRequiresDirectionalRelease() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)
            func direction(x: CGFloat, y: CGFloat) -> String? {
                hostView.accessoryToolbarJoystickDirectionForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }
            func acceptsRelease(x: CGFloat, y: CGFloat) -> Bool {
                hostView.accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }
            func acceptsActivation(x: CGFloat, y: CGFloat) -> Bool {
                hostView.accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }

            XCTAssertNil(direction(x: bounds.midX, y: bounds.midY))
            XCTAssertEqual(direction(x: bounds.midX + 12, y: bounds.midY), "right")
            XCTAssertEqual(direction(x: bounds.midX - 12, y: bounds.midY), "left")
            XCTAssertEqual(direction(x: bounds.midX, y: bounds.midY - 12), "up")
            XCTAssertEqual(direction(x: bounds.midX, y: bounds.midY + 12), "down")
            XCTAssertTrue(acceptsActivation(x: bounds.midX, y: bounds.minY - 11))
            XCTAssertFalse(acceptsActivation(x: bounds.midX, y: bounds.minY - 13))
            XCTAssertTrue(acceptsRelease(x: bounds.maxX + 99, y: bounds.midY))
            XCTAssertFalse(acceptsRelease(x: bounds.maxX + 101, y: bounds.midY))
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

        func testRemoteTerminalHostViewMatchesPhoneReportedColumnsLocally() throws {
            let phoneBounds = CGRect(x: 0, y: 0, width: 393, height: 700)
            let window = UIWindow(frame: phoneBounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: phoneBounds)
            hostView.userInterfaceIdiomOverrideForTesting = .phone
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: snapshot(columns: 80, rows: 24, text: "shell % which tailscale"),
                replayStateKey: "viewer|runtime=80x24|snapshot=80x24|interactive=0",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.5))

            let replayed = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertEqual(replayed.columns, GhosttyRemoteTerminalViewport.readablePhoneColumns(bounds: phoneBounds))

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

        func testRemoteTerminalHostViewDoesNotReplayAppliedOutputWhenQueueGrows() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let snapshot = snapshot(columns: 12, rows: 2, text: "shell % ")
            let firstBatch = GhosttyRemoteTerminalOutputBatch(id: "event-1", data: Data("!".utf8))
            let secondBatch = GhosttyRemoteTerminalOutputBatch(id: "event-2", data: Data("?".utf8))

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner-epoch",
                    bootstrapSnapshot: snapshot,
                    pendingOutputs: [firstBatch]
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let initialReplay = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let initialText = GhosttyTerminalSnapshotLayout.plainText(for: initialReplay)
            XCTAssertTrue(initialText.localizedStandardContains("shell % !"), initialText)

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner-epoch",
                    bootstrapSnapshot: snapshot,
                    pendingOutputs: [firstBatch, secondBatch]
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let replayed = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let replayedText = GhosttyTerminalSnapshotLayout.plainText(for: replayed)
            XCTAssertTrue(replayedText.localizedStandardContains("shell % !?"), replayedText)
            XCTAssertFalse(replayedText.localizedStandardContains("shell % !!?"), replayedText)

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
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)

            hostView.removeFromSuperview()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)
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
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)
            XCTAssertNotNil(hostView.capturedSnapshotForTesting())

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTeardownDoesNotBlockWhileFreeRuns() throws {
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
                replayStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=teardown",
                outputData: nil,
                outputEventToken: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)

            let freeCompleted = expectation(description: "background free completed")
            let originalSessionFreeHandler = GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting
            GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting = { _ in
                Thread.sleep(forTimeInterval: 0.5)
                freeCompleted.fulfill()
            }
            defer {
                GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting = originalSessionFreeHandler
            }

            let startedAt = Date()
            hostView.prepareForDismantle()
            let elapsed = Date().timeIntervalSince(startedAt)

            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)

            wait(for: [freeCompleted], timeout: 5)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewDoesNotRepublishInputReadinessWhenInstallingCallback() throws {
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

            hostView.setAcceptsTerminalInput(true)
            XCTAssertTrue(hostView.becomeFirstResponder())
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let unexpectedInitialPublication = expectation(description: "input readiness should not publish on callback install")
            unexpectedInitialPublication.isInverted = true
            hostView.onInputReadinessChanged = { _ in
                unexpectedInitialPublication.fulfill()
            }
            wait(for: [unexpectedInitialPublication], timeout: 0.2)

            let unexpectedResponderPublication = expectation(description: "input readiness should not track responder status")
            unexpectedResponderPublication.isInverted = true
            var reportedReadiness: [Bool] = []
            hostView.onInputReadinessChanged = { ready in
                reportedReadiness.append(ready)
                unexpectedResponderPublication.fulfill()
            }

            XCTAssertTrue(hostView.resignFirstResponder())
            wait(for: [unexpectedResponderPublication], timeout: 0.2)
            XCTAssertTrue(reportedReadiness.isEmpty)

            let readinessChanged = expectation(description: "input readiness changed after input was disabled")
            hostView.onInputReadinessChanged = { ready in
                reportedReadiness.append(ready)
                if ready == false { readinessChanged.fulfill() }
            }

            hostView.setAcceptsTerminalInput(false)
            wait(for: [readinessChanged], timeout: 2)
            XCTAssertEqual(reportedReadiness.last, false)

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
                Int32(0b0000_0111)
            )
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .ended)),
                Int32(0b0000_1000)
            )
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .possible)),
                Int32(0b0000_1100)
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

        func testRemoteTerminalHostViewUsesHistorySeedInsteadOfBootstrapSnapshotForScrollback() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 8, rows: 2, text: "SNAPSHOT_ONLY")
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner-epoch",
                    bootstrapSnapshot: bootstrapSnapshot,
                    historySeed: nil,
                    pendingOutputs: []
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner-epoch",
                    bootstrapSnapshot: bootstrapSnapshot,
                    historySeed: GhosttyRemoteTerminalOutputBatch(
                        id: "history|owner-epoch",
                        data: Data("history-only-line\nshell % ".utf8)
                    ),
                    pendingOutputs: []
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state…"
            )
            hostView.setAcceptsTerminalInput(true)
            _ = hostView.becomeFirstResponder()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let refreshedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let refreshedText = GhosttyTerminalSnapshotLayout.plainText(for: refreshedSnapshot)
            XCTAssertTrue(refreshedText.localizedStandardContains("history-only-line"), refreshedText)
            XCTAssertFalse(refreshedText.localizedStandardContains("SNAPSHOT"), refreshedText)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0,
                vertical: -2400,
                location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
            )
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertTrue(scrolledText.localizedStandardContains("history-only-line"), scrolledText)
            XCTAssertFalse(scrolledText.localizedStandardContains("SNAPSHOT"), scrolledText)

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
                let pendingOutputs: [GhosttyRemoteTerminalOutputBatch]
                if outputRepresentsFullHistory || outputData?.isEmpty != false {
                    pendingOutputs = []
                } else {
                    pendingOutputs = [GhosttyRemoteTerminalOutputBatch(id: outputEventToken ?? replayStateKey, data: outputData ?? Data())]
                }
                let historySeed: GhosttyRemoteTerminalOutputBatch? =
                    if outputRepresentsFullHistory, let outputData, !outputData.isEmpty {
                        GhosttyRemoteTerminalOutputBatch(id: outputEventToken ?? replayStateKey, data: outputData)
                    } else {
                        nil
                    }
                ownerEpoch = GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: epochID,
                    bootstrapSnapshot: snapshot,
                    historySeed: historySeed,
                    pendingOutputs: pendingOutputs
                )
            } else {
                ownerEpoch = nil
            }
            if outputRepresentsFullHistory {
                setAcceptsTerminalInput(true)
                _ = becomeFirstResponder()
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
