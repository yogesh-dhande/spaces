#if canImport(UIKit)
    import Darwin
    import Foundation
    import UIKit
    import XCTest
    import spacesterminalcore
    @testable import spacesterminalmobileghostty

    @MainActor
    final class GhosttyMobileAppServiceTests: XCTestCase {
        override func setUp() {
            super.setUp()
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = false
        }

        override func tearDown() {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            super.tearDown()
        }

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

        func testPhoneViewportKeepsRenderableSurfaceColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 80,
                rawRows: 24,
                bounds: CGRect(x: 0, y: 0, width: 393, height: 700),
                idiom: .phone
            )

            XCTAssertEqual(viewport.columns, 80)
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

        func testTouchScrollFingerDownMapsTowardOlderScrollback() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(
                forPanDelta: CGPoint(x: 0, y: 12),
                scaleFactor: 2
            )

            XCTAssertEqual(delta.y, 12)
        }

        func testTouchScrollFingerUpMapsTowardLiveBottom() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(
                forPanDelta: CGPoint(x: 0, y: -12),
                scaleFactor: 2
            )

            XCTAssertEqual(delta.y, -12)
        }

        func testTouchScrollUsesScaleFactorAsPointToPixelConversion() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(
                forPanDelta: CGPoint(x: 4, y: 10),
                scaleFactor: 3
            )

            XCTAssertEqual(delta.x, -6)
            XCTAssertEqual(delta.y, 15)
        }

        func testHighVelocityMomentumProducesBoundedDeltas() {
            let delta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(
                velocity: CGPoint(x: 20_000, y: 20_000),
                elapsed: 1,
                scaleFactor: 3
            )

            XCTAssertEqual(delta.x, -120)
            XCTAssertEqual(delta.y, 120)
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

        func testRemoteTerminalHostViewDoesNotCreateMirrorBeforeRenderState() throws {
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
                renderStateKey: "viewer|runtime=0x0|snapshot=0x0|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertFalse(hostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(hostView.subviews.contains { $0 is UILabel })

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
            XCTAssertNil(hostView.inputAccessoryView)

            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            XCTAssertEqual(accessoryView.intrinsicContentSize.height, 58)
            XCTAssertEqual(accessoryView.frame.height, 58)
            XCTAssertEqual(accessoryView.sizeThatFits(CGSize(width: 320, height: 0)).height, 58)
            XCTAssertTrue(accessoryView.autoresizingMask.contains(.flexibleHeight))

            let scrollView = try XCTUnwrap(descendants(of: accessoryView, matching: UIScrollView.self).first)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            let scrollableButtons = buttons.filter { $0.isDescendant(of: scrollView) }
            let pinnedButtons = buttons.filter { !$0.isDescendant(of: scrollView) }
            XCTAssertEqual(scrollableButtons.compactMap(\.accessibilityLabel), ["tab", "/", "~", "|", "-", "_", "esc", "Control", "Command", "Option"])
            XCTAssertEqual(pinnedButtons.compactMap(\.accessibilityLabel), ["Arrow key joystick", "Hide keyboard"])
            let joystickButton = try XCTUnwrap(pinnedButtons.first)
            XCTAssertEqual(joystickButton.accessibilityCustomActions?.map(\.name) ?? [], ["Up arrow", "Down arrow", "Left arrow", "Right arrow"])

            let phoneFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .phone)
            XCTAssertGreaterThan(phoneFrames.scrollView.width, 0)
            XCTAssertGreaterThan(phoneFrames.scrollContentSize.width, phoneFrames.scrollView.width)
            XCTAssertGreaterThanOrEqual(phoneFrames.joystickButton.minX, phoneFrames.scrollView.maxX + 5.5)
            XCTAssertGreaterThanOrEqual(phoneFrames.keyboardButton.minX, phoneFrames.joystickButton.maxX + 5.5)
            XCTAssertLessThanOrEqual(phoneFrames.keyboardButton.maxX, 312.5)
            XCTAssertEqual(phoneFrames.joystickButton.width, 46, accuracy: 0.5)
            XCTAssertEqual(phoneFrames.keyboardButton.width, 46, accuracy: 0.5)
            let phoneWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .phone)
            for width in phoneWidths.scrollable {
                XCTAssertEqual(width, 50, accuracy: 0.5)
            }
            for width in phoneWidths.pinned {
                XCTAssertEqual(width, 46, accuracy: 0.5)
            }

            let padFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .pad)
            XCTAssertGreaterThan(padFrames.scrollContentSize.width, padFrames.scrollView.width)
            XCTAssertGreaterThanOrEqual(padFrames.joystickButton.minX, padFrames.scrollView.maxX + 7.5)
            XCTAssertGreaterThanOrEqual(padFrames.keyboardButton.minX, padFrames.joystickButton.maxX + 7.5)
            XCTAssertLessThanOrEqual(padFrames.keyboardButton.maxX, 308.5)
            XCTAssertEqual(padFrames.joystickButton.width, 56, accuracy: 0.5)
            XCTAssertEqual(padFrames.keyboardButton.width, 56, accuracy: 0.5)
            let padWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .pad)
            for width in padWidths.scrollable {
                XCTAssertEqual(width, 64, accuracy: 0.5)
            }
            for width in padWidths.pinned {
                XCTAssertEqual(width, 56, accuracy: 0.5)
            }

            hostView.setSoftwareKeyboardVisible(false)
            XCTAssertEqual(hostView.accessoryToolbarButtonAccessibilityLabelsForTesting.pinned, ["Arrow key joystick", "Show keyboard"])

            hostView.setAcceptsTerminalInput(false)
            XCTAssertNil(hostView.inputAccessoryView)
        }

        func testRemoteTerminalAccessoryModifiersApplyToInput() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { sentText.append($0) }
            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            func tapButton(_ accessibilityLabel: String) throws {
                let button = try XCTUnwrap(buttons.first { $0.accessibilityLabel == accessibilityLabel })
                button.sendActions(for: .touchUpInside)
            }

            try tapButton("Control")
            hostView.insertText("c")

            try tapButton("Command")
            let joystickButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Arrow key joystick" })
            let leftArrowAction = try XCTUnwrap(joystickButton.accessibilityCustomActions?.first { $0.name == "Left arrow" })
            XCTAssertTrue(leftArrowAction.actionHandler?(leftArrowAction) ?? false)

            try tapButton("Command")
            hostView.deleteBackward()

            try tapButton("Option")
            hostView.deleteBackward()

            try tapButton("Command")
            hostView.insertText("k")

            XCTAssertEqual(sentKeys, ["ctrl+c", "cmd+left", "cmd+backspace", "opt+backspace", "cmd+k"])
            XCTAssertEqual(sentText, [])
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
            XCTAssertNil(direction(x: bounds.midX + 4, y: bounds.midY))
            XCTAssertEqual(direction(x: bounds.midX + 5, y: bounds.midY), "right")
            XCTAssertEqual(direction(x: bounds.midX - 5, y: bounds.midY), "left")
            XCTAssertEqual(direction(x: bounds.midX, y: bounds.midY - 5), "up")
            XCTAssertEqual(direction(x: bounds.midX, y: bounds.midY + 5), "down")
            XCTAssertTrue(acceptsActivation(x: bounds.minX - 7, y: bounds.midY))
            XCTAssertFalse(acceptsActivation(x: bounds.minX - 9, y: bounds.midY))
            XCTAssertTrue(acceptsActivation(x: bounds.midX, y: bounds.minY - 11))
            XCTAssertFalse(acceptsActivation(x: bounds.midX, y: bounds.minY - 13))
            XCTAssertTrue(acceptsRelease(x: bounds.maxX + 99, y: bounds.midY))
            XCTAssertFalse(acceptsRelease(x: bounds.maxX + 101, y: bounds.midY))
        }

        func testRemoteTerminalHostViewRendersSnapshot() throws {
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertGreaterThanOrEqual(renderedSnapshot.columns, 4)
            XCTAssertGreaterThanOrEqual(renderedSnapshot.rows, 2)
            XCTAssertEqual(renderedSnapshot.cells.first?.codepoint, UInt32(Character("h").unicodeScalars.first?.value ?? 0))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewKeepsPhoneSurfaceColumnsVisible() throws {
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
            hostView.setSurfaceViewportSizeForTesting(columns: 80, rows: 24)

            let wideText = String(repeating: ".", count: 42) + "WIDE"
            hostView.update(
                snapshot: snapshot(columns: 80, rows: 24, text: wideText),
                renderStateKey: "viewer|runtime=80x24|snapshot=80x24|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.5))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.columns, 80)
            XCTAssertTrue(renderedText.localizedStandardContains("WIDE"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewUsesKeyboardVisibleViewportForRenderedSnapshot() throws {
            let phoneBounds = CGRect(x: 0, y: 0, width: 393, height: 640)
            let window = UIWindow(frame: phoneBounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: phoneBounds)
            hostView.userInterfaceIdiomOverrideForTesting = .phone
            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in
                reportedViewports.append((columns: columns, rows: rows))
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let fullViewport = hostView.viewportSizeForTesting()
            let keyboardHeight: CGFloat = 260
            hostView.setKeyboardOccludedHeightForTesting(keyboardHeight)
            let keyboardOnlyViewport = hostView.viewportSizeForTesting()

            XCTAssertGreaterThan(fullViewport.rows, keyboardOnlyViewport.rows)
            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, 380, accuracy: 0.5)

            hostView.setAcceptsTerminalInput(true)
            hostView.setKeyboardOccludedHeightForTesting(keyboardHeight)
            viewController.view.layoutIfNeeded()
            let keyboardViewport = hostView.viewportSizeForTesting()

            XCTAssertLessThan(keyboardViewport.rows, keyboardOnlyViewport.rows)
            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, 322, accuracy: 0.5)
            XCTAssertEqual(hostView.surfaceHostFrameForTesting().height, phoneBounds.height, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(reportedViewports.last).rows, keyboardViewport.rows)

            let longSnapshot = promptAtBottomSnapshot(columns: 80, rows: fullViewport.rows + 20)
            hostView.update(
                snapshot: longSnapshot,
                renderStateKey: "viewer|runtime=80x\(longSnapshot.rows)|snapshot=80x\(longSnapshot.rows)|interactive=0",
                fallbackText: "Waiting for terminal state..."
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.rows, keyboardViewport.rows)
            XCTAssertTrue(renderedText.localizedStandardContains("shell %"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("SEQ 000000"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewUsesSurfaceRowsForKeyboardHiddenPrompt() throws {
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

            hostView.setAcceptsTerminalInput(true)
            XCTAssertTrue(hostView.becomeFirstResponder())
            hostView.setSoftwareKeyboardVisible(false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, phoneBounds.height - 58, accuracy: 0.5)
            let fallbackViewport = hostView.viewportSizeForTesting()
            let surfaceRows = max(fallbackViewport.rows - 12, 1)
            hostView.setSurfaceViewportSizeForTesting(columns: 80, rows: surfaceRows)

            let surfaceViewport = hostView.viewportSizeForTesting()
            XCTAssertEqual(surfaceViewport.columns, 80)
            XCTAssertEqual(surfaceViewport.rows, surfaceRows)

            let longSnapshot = promptAtBottomSnapshot(columns: 80, rows: surfaceRows + 20)
            hostView.update(
                snapshot: longSnapshot,
                renderStateKey: "viewer|runtime=80x\(longSnapshot.rows)|snapshot=80x\(longSnapshot.rows)|interactive=0|keyboard=hidden",
                fallbackText: "Waiting for terminal state..."
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.rows, surfaceRows)
            XCTAssertTrue(renderedText.localizedStandardContains("shell %"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("SEQ 000000"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRendersBootstrapSnapshotOnFreshSession() throws {
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertTrue(GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot).localizedStandardContains("hi"))
            XCTAssertFalse(GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot).localizedStandardContains("WRONG"))

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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=2",
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=teardown",
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
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
                    renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=\(cycle)",
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("hi"))

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPublishesRenderedTextAfterFreshOwnerSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "fresh owner snapshot published")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("shell % !") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 12, rows: 2, text: "shell % ")
            let refreshedSnapshot = snapshot(columns: 12, rows: 2, text: "shell % !")
            let ownerEpochID = "owner|test"
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: ownerEpochID,
                    bootstrapSnapshot: bootstrapSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state..."
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: ownerEpochID,
                    bootstrapSnapshot: refreshedSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state..."
            )

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("shell % !"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPublishesRepeatedTokenOutputWhenSnapshotCarriesIt() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 16, rows: 4, text: "shell % first\nsecond")
            let ownerEpochID = "owner|repeated-output-token"
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: ownerEpochID,
                    bootstrapSnapshot: bootstrapSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state..."
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertTrue(renderedText.localizedStandardContains("first"), renderedText)
            XCTAssertTrue(renderedText.localizedStandardContains("second"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsAutosuggestionOverwriteFromRenderedText() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "autosuggestion-cleared output published")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("t not found") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let ownerEpochID = "owner|autosuggestion-clear"
            let bootstrapSnapshot = snapshot(columns: 80, rows: 8, text: "shell % which t\nt not found\nshell % ")
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: ownerEpochID,
                    bootstrapSnapshot: bootstrapSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state..."
            )

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("t not found"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("ailscale"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewAppliesInitialOwnerPendingOutputOverBootstrapSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let renderedExpectation = expectation(description: "initial owner output repaired bootstrap snapshot")
            var renderedText = ""
            hostView.onRenderedTextChanged = { text in
                renderedText = text
                if text.localizedStandardContains("python not found") { renderedExpectation.fulfill() }
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let repairedSnapshot = snapshot(columns: 80, rows: 8, text: "shell % which python\npython not found\nshell % ")

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner|initial-output-repair",
                    bootstrapSnapshot: repairedSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state..."
            )

            wait(for: [renderedExpectation], timeout: 2)
            XCTAssertTrue(renderedText.localizedStandardContains("which python"), renderedText)
            XCTAssertTrue(renderedText.localizedStandardContains("python not found"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("check_for_update_on_startup"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("resu"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewRepublishesRenderedTextAfterVisibilityToggle() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            let initialRenderedExpectation = expectation(description: "initial rendered text published")
            let republishedRenderedExpectation = expectation(description: "rendered text republished after visibility toggle")
            republishedRenderedExpectation.expectedFulfillmentCount = 1

            var renderedEvents: [String] = []
            hostView.onRenderedTextChanged = { text in
                guard text.localizedStandardContains("hi") else { return }
                renderedEvents.append(text)
                if renderedEvents.count == 1 {
                    initialRenderedExpectation.fulfill()
                } else if renderedEvents.count == 2 {
                    republishedRenderedExpectation.fulfill()
                }
            }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(
                snapshot: nil,
                renderStateKey: "status",
                fallbackText: "Current owner: Mac"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.setTerminalVisible(true)
            hostView.update(
                snapshot: sampleSnapshot(),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [republishedRenderedExpectation], timeout: 2)
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.onRenderedTextChanged = nil
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…"
            )

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(
                snapshot: nil,
                renderStateKey: "status",
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
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended)),
                Int32(0b0000_1001)
            )
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .cancelled)),
                Int32(0b0000_1011)
            )
            XCTAssertEqual(
                Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .possible)),
                Int32(0b0000_1101)
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

        func testRemoteTerminalHostViewForwardsPreciseScrollMods() {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods in
                sentScrolls.append((horizontal, vertical, scrollMods))
            }

            XCTAssertTrue(
                hostView.debugSendScrollForTesting(
                    horizontal: 0,
                    vertical: 8,
                    hasPreciseDeltas: true,
                    momentumState: .changed
                )
            )

            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 8)
            XCTAssertEqual(sentScrolls.last?.scrollMods, Int32(0b0000_0111))
        }

        func testRemoteTerminalHostViewTinyScrollDeltaDoesNotForceRowJump() throws {
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
                snapshot: scrollbackSnapshot(lineCount: 220),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)

            XCTAssertTrue(hostView.debugSendScrollForTesting(horizontal: 0, vertical: 1))

            let tinyScrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: tinyScrolledSnapshot), bottomText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTinyScrollDeltasAccumulate() throws {
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
                snapshot: scrollbackSnapshot(lineCount: 220),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)

            for _ in 0..<20 {
                XCTAssertTrue(hostView.debugSendScrollForTesting(horizontal: 0, vertical: 1))
            }

            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertNotEqual(scrolledText, bottomText)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewCanScrollBackThroughSnapshotScrollback() throws {
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)
            XCTAssertTrue(bottomText.localizedStandardContains("SEQ 000219"), bottomText)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0,
                vertical: 10_000,
                location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
            )
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertNotEqual(scrolledText, bottomText)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)
            XCTAssertTrue(scrolledText.localizedStandardContains("SEQ 000001"), scrolledText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewPreservesSnapshotScrollbackAfterResizeChurn() throws {
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220),
                renderStateKey: "viewer|runtime=6x4|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            hostView.frame = CGRect(x: 0, y: 0, width: 700, height: 420)
            viewController.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0,
                vertical: 10_000,
                location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY)
            )
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertFalse(scrolledText.localizedStandardContains("SEQ 000219"), scrolledText)
            XCTAssertTrue(scrolledText.localizedStandardContains("SEQ 000001"), scrolledText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewResetsRenderedOutputForNewOwnerEpochWithSameSnapshot() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            let bootstrapSnapshot = snapshot(columns: 16, rows: 2, text: "old-output-line\nshell % ")
            let refreshedBootstrapSnapshot = snapshot(columns: 16, rows: 2, text: "shell % ")
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner-epoch-1",
                    bootstrapSnapshot: bootstrapSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let outputSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let outputText = GhosttyTerminalSnapshotLayout.plainText(for: outputSnapshot)
            XCTAssertTrue(outputText.localizedStandardContains("old-output-line"), outputText)

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: "owner-epoch-2",
                    bootstrapSnapshot: refreshedBootstrapSnapshot
                ),
                endedRender: nil,
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let refreshedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let refreshedText = GhosttyTerminalSnapshotLayout.plainText(for: refreshedSnapshot)
            XCTAssertFalse(refreshedText.localizedStandardContains("old-output-line"), refreshedText)
            XCTAssertTrue(refreshedText.localizedStandardContains("shell %"), refreshedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewClearsStaleSnapshotBeforeFreshSnapshot() throws {
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
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: promptSnapshot(),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…"
            )

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedSnapshotText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertFalse(renderedSnapshotText.localizedStandardContains("hi"), renderedSnapshotText)
            XCTAssertTrue(renderedSnapshotText.localizedStandardContains("shell %"), renderedSnapshotText)
            XCTAssertEqual(renderedSnapshotText.components(separatedBy: "shell %").count - 1, 1, renderedSnapshotText)

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

        private func scrollbackSnapshot(lineCount: Int) -> GhosttyTerminalSnapshot {
            let lines = (0..<lineCount).map { index in "SEQ \(String(format: "%06d", index)) scrollback-line-\(index)" }
            return snapshot(columns: 80, rows: lineCount, text: lines.joined(separator: "\n"))
        }

        private func promptAtBottomSnapshot(columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
            let historyRows = max(rows - 1, 0)
            let lines = (0..<historyRows).map { index in "SEQ \(String(format: "%06d", index)) keyboard-safe-row-\(index)" }
            return snapshot(columns: columns, rows: rows, text: (lines + ["shell %"]).joined(separator: "\n"))
        }

        private func snapshotSignature(_ snapshot: GhosttyTerminalSnapshot?) -> String {
            guard let snapshot else { return "nil" }
            let sampleCells = snapshot.cells.prefix(12).map { "\($0.codepoint):\($0.flags)" }.joined(separator: ",")
            return "\(snapshot.columns)x\(snapshot.rows)|cursor=\(snapshot.cursorColumn),\(snapshot.cursorRow)|cells=\(sampleCells)"
        }

        private func snapshot(columns: Int, rows: Int, text: String) -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let cellCount = max(columns * rows, 0)
            var cells = Array(repeating: blank, count: cellCount)
            var cursorColumn = 0
            var cursorRow = 0

            for scalar in text.unicodeScalars where rows > 0 && columns > 0 {
                if scalar == "\n" {
                    cursorColumn = 0
                    cursorRow += 1
                    continue
                }
                guard cursorRow < rows else { break }
                if cursorColumn >= columns {
                    cursorColumn = 0
                    cursorRow += 1
                }
                guard cursorRow < rows else { break }
                let cellIndex = cursorRow * columns + cursorColumn
                cells[cellIndex] = GhosttyTerminalSnapshot.Cell(
                    codepoint: scalar.value,
                    foregroundRGB: 0xF2F2F2,
                    backgroundRGB: 0x1A1E26,
                    flags: 0
                )
                cursorColumn += 1
            }

            return GhosttyTerminalSnapshot(
                columns: columns,
                rows: rows,
                cursorColumn: min(max(cursorColumn, 0), max(columns - 1, 0)),
                cursorRow: min(max(cursorRow, 0), max(rows - 1, 0)),
                cursorVisible: true,
                defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26,
                cells: cells
            )
        }

    }

    private func descendants<ViewType: UIView>(of view: UIView, matching type: ViewType.Type) -> [ViewType] {
        var matches: [ViewType] = []
        if let typedView = view as? ViewType { matches.append(typedView) }
        for subview in view.subviews {
            matches.append(contentsOf: descendants(of: subview, matching: type))
        }
        return matches
    }

    private extension GhosttyRemoteTerminalHostView {
        func update(
            snapshot: GhosttyTerminalSnapshot?,
            renderStateKey: String,
            fallbackText: String
        ) {
            let ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?
            if snapshot != nil {
                let epochID = "owner|\(renderStateKey)|\(snapshotSignature(snapshot))"
                ownerEpoch = GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session",
                    id: epochID,
                    bootstrapSnapshot: snapshot
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
