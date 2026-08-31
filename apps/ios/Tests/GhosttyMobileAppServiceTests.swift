#if canImport(UIKit)
    import Foundation
    import GhosttyKit
    import UIKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile
    @testable import spacesterminalmobileghostty

    @MainActor final class GhosttyMobileAppServiceTests: XCTestCase {
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

        func testMobileActionParserParsesOpenURLAndMouseOverLinkEvents() {
            var open = ghostty_action_s()
            open.tag = GHOSTTY_ACTION_OPEN_URL
            "https://example.com/movie.mp4".withCString { pointer in
                open.action.open_url = ghostty_action_open_url_s(
                    kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: pointer, len: UInt("https://example.com/movie.mp4".utf8.count))
                XCTAssertEqual(GhosttyMobileActionEventParser.parse(open), .openURL(kind: .unknown, value: "https://example.com/movie.mp4"))
            }

            var hover = ghostty_action_s()
            hover.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
            "image.png".withCString { pointer in
                hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: pointer, len: "image.png".utf8.count)
                XCTAssertEqual(GhosttyMobileActionEventParser.parse(hover), .mouseOverLink("image.png"))
            }
            hover.action.mouse_over_link = ghostty_action_mouse_over_link_s(url: nil, len: 0)
            XCTAssertEqual(GhosttyMobileActionEventParser.parse(hover), .mouseOverLink(nil))
        }

        func testRuntimeActionCallbackDispatchesMainThreadOpenURLSynchronously() {
            let service = GhosttyMobileAppService.shared
            let surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
            let url = "https://example.com/image.png"
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = surface
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_OPEN_URL
            var handledEvents: [GhosttyMobileActionEvent] = []

            service.registerActionHandler(for: surface) { event in handledEvents.append(event) }
            defer { service.unregisterActionHandler(for: surface) }

            url.withCString { pointer in
                action.action.open_url = ghostty_action_open_url_s(
                    kind: GHOSTTY_ACTION_OPEN_URL_KIND_UNKNOWN, url: pointer, len: UInt(url.utf8.count))
                let runtimeConfig = GhosttyMobileAppService.makeRuntimeConfig()
                XCTAssertTrue(runtimeConfig.action_cb(nil, target, action))
                XCTAssertEqual(handledEvents, [.openURL(kind: .unknown, value: url)])
            }
        }

        func testPhoneViewportKeepsRenderableSurfaceColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 80, rawRows: 24, bounds: CGRect(x: 0, y: 0, width: 393, height: 700), idiom: .phone)

            XCTAssertEqual(viewport.columns, 80)
            XCTAssertEqual(viewport.rows, 24)
        }

        func testPadViewportKeepsGhosttyColumns() {
            let viewport = GhosttyRemoteTerminalViewport.reportedSize(
                rawColumns: 120, rawRows: 40, bounds: CGRect(x: 0, y: 0, width: 1024, height: 900), idiom: .pad)

            XCTAssertEqual(viewport.columns, 120)
            XCTAssertEqual(viewport.rows, 40)
        }

        func testTouchScrollFingerDownMapsTowardOlderScrollback() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: 0, y: 12), scaleFactor: 2)

            XCTAssertEqual(delta.y, 12)
        }

        func testTouchScrollFingerUpMapsTowardLiveBottom() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: 0, y: -12), scaleFactor: 2)

            XCTAssertEqual(delta.y, -12)
        }

        func testTouchScrollUsesScaleFactorAsPointToPixelConversion() {
            let delta = GhosttyRemoteTerminalScrollMapper.scrollDelta(forPanDelta: CGPoint(x: 4, y: 10), scaleFactor: 3)

            XCTAssertEqual(delta.x, -6)
            XCTAssertEqual(delta.y, 15)
        }

        func testHighVelocityMomentumProducesBoundedDeltas() {
            let delta = GhosttyRemoteTerminalScrollMapper.momentumFrameDelta(velocity: CGPoint(x: 20_000, y: 20_000), elapsed: 1, scaleFactor: 3)

            XCTAssertEqual(delta.x, -120)
            XCTAssertEqual(delta.y, 120)
        }

        func testResolveResourcesPathUsesBundledGhosttyResources() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let bundledResources = root.appendingPathComponent("ghostty", isDirectory: true)
            try FileManager.default.createDirectory(at: bundledResources, withIntermediateDirectories: true)

            let resolved = try GhosttyMobileAppService.resolveResourcesPath(
                environment: [:], bundleResourceURL: root,
                sourceFilePath: "/unavailable/Sources/spacesterminalmobileghostty/GhosttyMobileAppService.swift")

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
                homeDirectory: home, applicationSupportDirectory: support, cachesDirectory: caches,
                setEnvironment: { name, value, overwrite in
                    environment[name] = (value, overwrite)
                    return 0
                })

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
                })

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
                })

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
                })

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
                snapshot: nil, renderStateKey: "viewer|runtime=0x0|snapshot=0x0|interactive=0", fallbackText: "Waiting for terminal state…")

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

        func testRemoteTerminalHostViewTapOnLinkConsumesTapBeforeFocus() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            hostView.setAcceptsTerminalInput(true)
            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            hostView.debugTapLinkHandlerForTesting = { point in
                XCTAssertEqual(point, CGPoint(x: 12, y: 18))
                return true
            }

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink)

            hostView.setAcceptsTerminalInput(false)
            hostView.debugTapLinkHandlerForTesting = { point in
                XCTAssertEqual(point, CGPoint(x: 12, y: 18))
                return true
            }
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink)

            hostView.debugTapLinkHandlerForTesting = { _ in false }
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .ignored)

            hostView.setAcceptsTerminalInput(true)
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)
        }

        /// An iOS tap never drives the remote application's mouse (#465): a tap that misses a link only
        /// focuses the keyboard, whether or not the session's own terminal is tracking the mouse.
        func testRemoteTerminalHostViewTapNeverSendsMouseClickEvenWhenMouseCaptured() {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
            hostView.setAcceptsTerminalInput(true)
            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            hostView.debugTapLinkHandlerForTesting = { _ in false }
            hostView.debugMouseCapturedForTesting = true

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)

            hostView.debugMouseCapturedForTesting = false
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)
        }

        /// A tap on a URL opens the link on the phone even while the session's application is tracking
        /// the mouse, and that tap never reaches the application: iOS taps never drive the remote
        /// application's mouse (#465), so every tap either opens a link locally or only focuses the
        /// keyboard.
        func testRemoteTerminalHostViewTapOnLinkOpensLocallyWhileOtherTapsOnlyFocus() {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
            hostView.setAcceptsTerminalInput(true)
            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            hostView.debugMouseCapturedForTesting = true
            var probedPoints: [CGPoint] = []
            hostView.debugTapLinkHandlerForTesting = { point in
                probedPoints.append(point)
                return point.y < 100
            }

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink)
            XCTAssertEqual(probedPoints, [CGPoint(x: 12, y: 18)])

            XCTAssertEqual(
                hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 150)), .focused, "a tap off a link only focuses the keyboard")
        }

        /// While the phone shows a frame narrower than the host's grid (every frame between taking
        /// ownership and the owner runtime resizing to the phone's width), a tap must not activate a link
        /// at all. The probe joins the rows the frame marks as soft-wrapped, and those marks survive a
        /// column crop while the columns past the phone's width do not, so probing there yields a link the
        /// user never saw (#492). The tap falls through to the ordinary handling instead, and the same tap
        /// once the frame is full width opens the link.
        func testRemoteTerminalHostViewTapDoesNotProbeForLinksWhileTheFrameIsCropped() {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 100, height: 200))
            hostView.setAcceptsTerminalInput(true)
            var probeCount = 0
            hostView.debugTapLinkHandlerForTesting = { _ in
                probeCount += 1
                return true
            }

            XCTAssertFalse(
                hostView.debugAppliedFrameCoversHostColumnsForTesting, "a view that has applied no frame must not be treated as showing one")
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)
            XCTAssertEqual(probeCount, 0, "a frame narrower than the host's grid must not be probed for links")

            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink)
            XCTAssertEqual(probeCount, 1)
        }

        /// The coverage the link guard reads is recorded from the frame the mirror applied, so it has to
        /// track the width the phone is cropping away: a Mac-width snapshot in a phone-width viewport
        /// reaches the surface with columns missing, and the same snapshot at the viewport's own width
        /// reaches it whole. A snapshot with more rows than the viewport shows is still full width, so it
        /// stays link-activatable: the phone shows fewer rows than the session constantly (the keyboard
        /// alone takes a third of them), and the rows it does show are intact.
        func testRemoteTerminalHostViewRecordsWhetherTheAppliedFrameCoversTheHostWidth() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "host-grid-coverage") { view in
                view.setSurfaceViewportSizeForTesting(columns: 49, rows: 20)
            }
            defer { hostView.removeFromSuperview() }

            hostView.update(snapshot: filledSnapshot(columns: 105, rows: 20), renderStateKey: "owner|mac-width", fallbackText: "")
            XCTAssertFalse(
                hostView.debugAppliedFrameCoversHostColumnsForTesting, "a 105-column host grid in a 49-column viewport reaches the surface as a slice"
            )

            hostView.update(snapshot: filledSnapshot(columns: 49, rows: 20), renderStateKey: "owner|phone-width", fallbackText: "")
            XCTAssertTrue(hostView.debugAppliedFrameCoversHostColumnsForTesting, "a host grid the viewport fits reaches the surface whole")

            hostView.update(snapshot: filledSnapshot(columns: 49, rows: 40), renderStateKey: "owner|phone-width-tall", fallbackText: "")
            XCTAssertTrue(
                hostView.debugAppliedFrameCoversHostColumnsForTesting,
                "a grid taller than the viewport still shows its rows at full width, so links stay activatable")

            hostView.prepareForDismantle()
            XCTAssertFalse(hostView.debugAppliedFrameCoversHostColumnsForTesting, "releasing the mirror drops what it recorded about the surface")
        }

        /// End-to-end coverage for the #492 gate: a tap on a frame the mirror actually applied as a
        /// column-cropped slice must not probe for a link at all, and the same session's tap probes
        /// normally again once a frame covering the viewport's columns has been applied. The other tests
        /// around this one check the two halves separately (that the coverage flag tracks a real applied
        /// frame's width, and that the tap gate reads whatever the flag says); this one drives both
        /// halves together through the real `update(snapshot:)` apply path and the real tap entry point,
        /// which is what the deleted UI-test phase used to be the only coverage for.
        func testTapOnAColumnCroppedFrameDoesNotProbeLinks() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "tap-crop-gate") { view in
                view.setSurfaceViewportSizeForTesting(columns: 49, rows: 20)
            }
            defer { hostView.removeFromSuperview() }
            hostView.setAcceptsTerminalInput(true)

            var probeCount = 0
            hostView.debugTapLinkHandlerForTesting = { _ in
                probeCount += 1
                return true
            }

            hostView.update(snapshot: filledSnapshot(columns: 105, rows: 20), renderStateKey: "owner|mac-width", fallbackText: "")
            XCTAssertFalse(
                hostView.debugAppliedFrameCoversHostColumnsForTesting, "sanity: the applied frame is a column-cropped slice of the host grid")
            XCTAssertEqual(
                hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused,
                "a tap on a column-cropped frame must fall through to focusing the keyboard, not open a link")
            XCTAssertEqual(probeCount, 0, "a column-cropped frame must never reach the link probe")

            hostView.update(snapshot: filledSnapshot(columns: 49, rows: 20), renderStateKey: "owner|phone-width", fallbackText: "")
            XCTAssertTrue(hostView.debugAppliedFrameCoversHostColumnsForTesting, "sanity: the applied frame now covers the viewport's columns")
            XCTAssertEqual(
                hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .openedLink,
                "a frame covering the host's columns allows the tap to probe for a link")
            XCTAssertEqual(probeCount, 1)
        }

        private func filledSnapshot(columns: Int, rows: Int, selection: GhosttyTerminalSelectionRange? = nil) -> GhosttyTerminalSnapshot {
            GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: 0, cursorRow: 0, cursorVisible: false, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26,
                cells: (0..<(columns * rows)).map { index in
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: UnicodeScalar("a").value + UInt32(index % 26), foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
                }, selection: selection)
        }

        /// While the daemon's shared selection is present, a plain tap is exclusively a clear gesture: it
        /// neither probes for a link nor focuses the keyboard, matching `handleTapToActivateInput`'s
        /// documented precedence. The highlight itself is left untouched here; only the daemon's next
        /// frame (carrying no selection) or a fresh applied frame can make it disappear.
        func testRemoteTerminalHostViewTapWithSelectionPresentClearsInsteadOfProbingOrFocusing() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            hostView.setAcceptsTerminalInput(true)
            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            var linkProbeCount = 0
            hostView.debugTapLinkHandlerForTesting = { _ in
                linkProbeCount += 1
                return true
            }
            var clearCount = 0
            hostView.onClearSelectionTapped = { clearCount += 1 }
            let selection = GhosttyTerminalSelectionRange(
                startColumn: 0, startRow: 0, endColumn: 5, endRow: 0, isRectangle: false, extendsAbove: false, extendsBelow: false)
            hostView.update(snapshot: filledSnapshot(columns: 40, rows: 10, selection: selection), renderStateKey: "selection", fallbackText: "")

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .clearedSelection)

            XCTAssertEqual(clearCount, 1)
            XCTAssertEqual(linkProbeCount, 0, "a selection-clearing tap must not also probe for a link")
        }

        /// On an ended session's frozen final frame the selection can never change again and the daemon
        /// rejects a clear with `sessionNotRunning`, so a tap on a selection-bearing ended render falls
        /// through to the normal link-probe/focus handling instead of clearing. The link probe itself
        /// synthesizes a click that mutates the mirror surface (Ghostty clears a selection on left
        /// press), so the fall-through must also re-apply the frozen frame afterward to keep the
        /// surface canonical; `reappliedEndedRenderFrameCountForTesting` is the seam that lets this test
        /// see that re-apply happened.
        func testRemoteTerminalHostViewTapWithSelectionOnEndedRenderDoesNotClear() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            hostView.setAcceptsTerminalInput(true)
            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            hostView.debugTapLinkHandlerForTesting = { _ in false }
            var clearCount = 0
            hostView.onClearSelectionTapped = { clearCount += 1 }
            let selection = GhosttyTerminalSelectionRange(
                startColumn: 0, startRow: 0, endColumn: 5, endRow: 0, isRectangle: false, extendsAbove: false, extendsBelow: false)
            let endedRender = GhosttyRemoteTerminalEndedRender(id: "ended", snapshot: filledSnapshot(columns: 40, rows: 10, selection: selection))
            hostView.update(ownerEpoch: nil, endedRender: endedRender, fallbackText: "")
            let reappliedCountBeforeTap = hostView.reappliedEndedRenderFrameCountForTesting

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)

            XCTAssertEqual(clearCount, 0)
            // `debugTapLinkHandlerForTesting` stands in for the real link probe here, so this cannot
            // observe the probe's synthesized click actually clearing the mirror surface's own
            // selection; it instead confirms the fall-through unconditionally re-applies the frozen
            // ended render's frame afterward, which is what heals the surface once the probe mutates it.
            XCTAssertEqual(
                hostView.reappliedEndedRenderFrameCountForTesting, reappliedCountBeforeTap + 1,
                "a tap on an ended frame must re-apply the frozen frame after the link probe runs")
        }

        /// A frame that carries no selection leaves the pre-existing tap handling (link probe, then
        /// focus) untouched, and never calls `onClearSelectionTapped`: the clear path only engages while
        /// the daemon actually has a shared selection to clear.
        func testRemoteTerminalHostViewTapWithoutSelectionPresentBehavesAsBeforeAndSendsNoClear() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            hostView.setAcceptsTerminalInput(true)
            hostView.debugAppliedFrameCoversHostColumnsForTesting = true
            hostView.debugTapLinkHandlerForTesting = { _ in false }
            var clearCount = 0
            hostView.onClearSelectionTapped = { clearCount += 1 }
            hostView.update(snapshot: filledSnapshot(columns: 40, rows: 10), renderStateKey: "no-selection", fallbackText: "")

            XCTAssertEqual(hostView.debugTapToActivateInputForTesting(at: CGPoint(x: 12, y: 18)), .focused)

            XCTAssertEqual(clearCount, 0)
        }

        func testRemoteTerminalHostViewDispatchesOpenURLAction() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var openedLinks: [String] = []
            hostView.onOpenLink = { openedLinks.append($0) }

            hostView.debugApplyActionEventForTesting(.openURL(kind: .unknown, value: "https://example.com/image.png"))
            hostView.debugApplyActionEventForTesting(.mouseOverLink("https://example.com/image.png"))

            XCTAssertEqual(openedLinks, ["https://example.com/image.png"])
        }

        func testRemoteTerminalHostViewIgnoresHoveredLinkDuringTapProbe() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var openedLinks: [String] = []
            hostView.onOpenLink = { openedLinks.append($0) }

            XCTAssertFalse(hostView.debugApplyActionEventsDuringTapProbeForTesting([.mouseOverLink(" image.png ")]))

            XCTAssertEqual(openedLinks, [])
        }

        func testRemoteTerminalHostViewOpensFullURLAfterTruncatedHoverDuringTapProbe() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            let fullPath = "/Users/yogesh/Downloads/Screen Recording 2026-03-20 at 11.17.57 AM.mov"
            var openedLinks: [String] = []
            hostView.onOpenLink = { openedLinks.append($0) }

            XCTAssertTrue(
                hostView.debugApplyActionEventsDuringTapProbeForTesting([
                    .mouseOverLink("/Users/yogesh/Downloads/Screen"), .openURL(kind: .unknown, value: fullPath),
                ]))

            XCTAssertEqual(openedLinks, [fullPath])
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
            XCTAssertEqual(accessoryView.intrinsicContentSize.height, 46)
            XCTAssertEqual(accessoryView.frame.height, 46)
            XCTAssertEqual(accessoryView.sizeThatFits(CGSize(width: 320, height: 0)).height, 46)
            XCTAssertTrue(accessoryView.autoresizingMask.contains(.flexibleHeight))

            let scrollView = try XCTUnwrap(descendants(of: accessoryView, matching: UIScrollView.self).first)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            let scrollableButtons = buttons.filter { $0.isDescendant(of: scrollView) }
            let pinnedButtons = buttons.filter { !$0.isDescendant(of: scrollView) }
            XCTAssertEqual(
                scrollableButtons.compactMap(\.accessibilityLabel),
                ["Paste", "tab", "/", "~", "|", "-", "_", "esc", "Shift", "Control", "Command", "Option"])
            XCTAssertEqual(scrollableButtons.first?.accessibilityIdentifier, "terminal.accessory.paste")
            XCTAssertEqual(pinnedButtons.compactMap(\.accessibilityLabel), ["Compose message", "Arrow key joystick", "Hide keyboard"])
            let joystickButton = try XCTUnwrap(pinnedButtons.first { $0.accessibilityLabel == "Arrow key joystick" })
            XCTAssertEqual(joystickButton.accessibilityCustomActions?.map(\.name) ?? [], ["Up arrow", "Down arrow", "Left arrow", "Right arrow"])

            let phoneFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .phone)
            XCTAssertGreaterThan(phoneFrames.scrollView.width, 0)
            XCTAssertGreaterThan(phoneFrames.scrollContentSize.width, phoneFrames.scrollView.width)
            XCTAssertGreaterThanOrEqual(phoneFrames.joystickButton.minX, phoneFrames.scrollView.maxX + 4.5)
            XCTAssertGreaterThanOrEqual(phoneFrames.keyboardButton.minX, phoneFrames.joystickButton.maxX + 4.5)
            XCTAssertLessThanOrEqual(phoneFrames.keyboardButton.maxX, 314.5)
            XCTAssertEqual(phoneFrames.joystickButton.width, 40, accuracy: 0.5)
            XCTAssertEqual(phoneFrames.keyboardButton.width, 40, accuracy: 0.5)
            let phoneWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .phone)
            // The leading Paste button is an icon button, so it takes the icon width the pinned icon
            // buttons use; the rest of the scrollable row keeps the text-button width.
            XCTAssertEqual(phoneWidths.scrollable.first ?? 0, 40, accuracy: 0.5)
            for width in phoneWidths.scrollable.dropFirst() { XCTAssertEqual(width, 44, accuracy: 0.5) }
            for width in phoneWidths.pinned { XCTAssertEqual(width, 40, accuracy: 0.5) }

            let padFrames = hostView.accessoryToolbarLayoutFramesForTesting(width: 320, userInterfaceIdiom: .pad)
            XCTAssertGreaterThan(padFrames.scrollContentSize.width, padFrames.scrollView.width)
            XCTAssertGreaterThanOrEqual(padFrames.joystickButton.minX, padFrames.scrollView.maxX + 5.5)
            XCTAssertGreaterThanOrEqual(padFrames.keyboardButton.minX, padFrames.joystickButton.maxX + 5.5)
            XCTAssertLessThanOrEqual(padFrames.keyboardButton.maxX, 310.5)
            XCTAssertEqual(padFrames.joystickButton.width, 48, accuracy: 0.5)
            XCTAssertEqual(padFrames.keyboardButton.width, 48, accuracy: 0.5)
            let padWidths = hostView.accessoryToolbarButtonWidthsForTesting(width: 320, userInterfaceIdiom: .pad)
            XCTAssertEqual(padWidths.scrollable.first ?? 0, 48, accuracy: 0.5)
            for width in padWidths.scrollable.dropFirst() { XCTAssertEqual(width, 58, accuracy: 0.5) }
            for width in padWidths.pinned { XCTAssertEqual(width, 48, accuracy: 0.5) }

            hostView.setSoftwareKeyboardVisible(false)
            XCTAssertEqual(
                hostView.accessoryToolbarButtonAccessibilityLabelsForTesting.pinned, ["Compose message", "Arrow key joystick", "Show keyboard"])

            hostView.setAcceptsTerminalInput(false)
            XCTAssertNil(hostView.inputAccessoryView)
        }

        func testRemoteTerminalJoystickSwipeDirectionIgnoresStartLocation() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            // Start near the right edge, then slide left: the swipe direction wins and only
            // "left" fires. The starting location never dispatches a key on its own.
            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 44, y: 18), bounds: bounds, initialDelay: .seconds(10), interval: .seconds(10))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 10, y: 18))
            hostView.accessoryToolbarEndJoystickTrackingForTesting()

            XCTAssertEqual(sentKeys, ["left"])
        }

        func testRemoteTerminalJoystickStationaryTapSendsNothing() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            // A press and release without sliding past the activation distance stays neutral.
            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 30, y: 18), bounds: bounds, initialDelay: .milliseconds(50), interval: .milliseconds(10))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 34, y: 18))
            hostView.accessoryToolbarEndJoystickTrackingForTesting()

            XCTAssertEqual(sentKeys, [])
        }

        func testRemoteTerminalJoystickHoldRepeatsSwipedDirection() async throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 23, y: 18), bounds: bounds, initialDelay: .milliseconds(5), interval: .milliseconds(5))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 0, y: 18))

            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while sentKeys.count < 4, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            hostView.accessoryToolbarEndJoystickTrackingForTesting()
            let countAtRelease = sentKeys.count

            XCTAssertGreaterThanOrEqual(countAtRelease, 4, "holding a swipe should emit the first key plus repeats")
            XCTAssertTrue(sentKeys.allSatisfy { $0 == "left" })

            // Releasing stops further repeats.
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(sentKeys.count, countAtRelease)
        }

        func testRemoteTerminalJoystickChangingSwipeSwitchesDirection() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.setAcceptsTerminalInput(true)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)

            // Long delays keep repeats from firing, isolating the per-direction key.
            hostView.accessoryToolbarBeginJoystickTrackingForTesting(
                at: CGPoint(x: 23, y: 18), bounds: bounds, initialDelay: .seconds(10), interval: .seconds(10))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 46, y: 18))
            hostView.accessoryToolbarMoveJoystickTrackingForTesting(to: CGPoint(x: 0, y: 18))
            hostView.accessoryToolbarEndJoystickTrackingForTesting()

            XCTAssertEqual(sentKeys, ["right", "left"])
        }

        func testRemoteTerminalAccessoryModifiersApplyToInput() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { text, _ in sentText.append(text) }
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

        /// Return arrives as plain text with no modifier flags, so the accessory's Shift is the only way
        /// to reach Shift+Enter on a device with no hardware keyboard. An unmodified Return must still be
        /// a plain Enter.
        func testRemoteTerminalAccessoryShiftAppliesToReturn() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [String] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { text, _ in sentText.append(text) }
            hostView.setAcceptsTerminalInput(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            let shiftButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Shift" })

            shiftButton.sendActions(for: .touchUpInside)
            hostView.insertText("\n")
            // The modifier is consumed by that one press, so the next Return is unmodified again.
            hostView.insertText("\n")

            XCTAssertEqual(sentKeys, ["shift+enter", "enter"])
            XCTAssertEqual(sentText, [])
        }

        func testRemoteTerminalPasteMarksTextAsPaste() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentText: [(String, Bool)] = []
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.setAcceptsTerminalInput(true)

            hostView.pasteTextForTesting("line one\nline two")

            XCTAssertEqual(sentText.count, 1)
            XCTAssertEqual(sentText.first?.0, "line one\nline two")
            XCTAssertEqual(sentText.first?.1, true)
        }

        func testRemoteTerminalAccessoryPasteButtonSendsClipboardAsPaste() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentText: [(String, Bool)] = []
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.setAcceptsTerminalInput(true)
            hostView.setClipboardTextForTesting("clipboard payload")

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let pasteButton = try XCTUnwrap(descendants(of: accessoryView, matching: UIButton.self).first { $0.accessibilityLabel == "Paste" })
            pasteButton.sendActions(for: .touchUpInside)

            XCTAssertEqual(sentText.count, 1)
            XCTAssertEqual(sentText.first?.0, "clipboard payload")
            XCTAssertEqual(sentText.first?.1, true)
        }

        /// The accessory Command modifier followed by "v" is the only way to reach cmd+v without a
        /// hardware keyboard. It has to paste rather than fall through to the text path, which would type
        /// a literal "v"; an empty clipboard still consumes the keystroke instead of typing one.
        func testRemoteTerminalAccessoryCommandVPastesClipboard() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [(String, Bool)] = []
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.setAcceptsTerminalInput(true)
            hostView.setClipboardTextForTesting("clipboard payload")

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let buttons = descendants(of: accessoryView, matching: UIButton.self)
            let commandButton = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "Command" })

            commandButton.sendActions(for: .touchUpInside)
            hostView.insertText("v")

            XCTAssertEqual(sentKeys, [])
            XCTAssertEqual(sentText.count, 1)
            XCTAssertEqual(sentText.first?.0, "clipboard payload")
            XCTAssertEqual(sentText.first?.1, true)

            // The modifier is consumed, so the next "v" is plain typed text again.
            hostView.insertText("v")
            XCTAssertEqual(sentText.count, 2)
            XCTAssertEqual(sentText.last?.0, "v")
            XCTAssertEqual(sentText.last?.1, false)

            hostView.setClipboardTextForTesting(nil)
            commandButton.sendActions(for: .touchUpInside)
            hostView.insertText("v")

            XCTAssertEqual(sentText.count, 2, "an empty clipboard must swallow cmd+v rather than type a literal v")
            XCTAssertEqual(sentKeys, [])
        }

        /// An image on the clipboard belongs in the composer, not in the session: every paste route hands
        /// the paste to the image handler and sends nothing, even when the clipboard also carries text.
        func testRemoteTerminalAccessoryPasteButtonWithClipboardImageDefersToImageHandler() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentText: [(String, Bool)] = []
            var imageHandlerCallCount = 0
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.onPasteClipboardImage = {
                imageHandlerCallCount += 1
                return true
            }
            hostView.setAcceptsTerminalInput(true)
            hostView.setClipboardTextForTesting("clipboard payload")
            hostView.setClipboardHasImageForTesting(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let pasteButton = try XCTUnwrap(descendants(of: accessoryView, matching: UIButton.self).first { $0.accessibilityLabel == "Paste" })
            pasteButton.sendActions(for: .touchUpInside)

            XCTAssertEqual(imageHandlerCallCount, 1)
            XCTAssertEqual(sentText.count, 0, "a clipboard image must not be pasted into the terminal")

            // The system Paste command shares the same route.
            hostView.paste(nil)
            XCTAssertEqual(imageHandlerCallCount, 2)
            XCTAssertEqual(sentText.count, 0)
        }

        func testRemoteTerminalAccessoryCommandVWithClipboardImageDefersToImageHandler() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentKeys: [String] = []
            var sentText: [(String, Bool)] = []
            var imageHandlerCallCount = 0
            hostView.onSendKey = { sentKeys.append($0) }
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.onPasteClipboardImage = {
                imageHandlerCallCount += 1
                return true
            }
            hostView.setAcceptsTerminalInput(true)
            hostView.setClipboardTextForTesting("clipboard payload")
            hostView.setClipboardHasImageForTesting(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let commandButton = try XCTUnwrap(descendants(of: accessoryView, matching: UIButton.self).first { $0.accessibilityLabel == "Command" })

            commandButton.sendActions(for: .touchUpInside)
            hostView.insertText("v")

            XCTAssertEqual(imageHandlerCallCount, 1)
            XCTAssertEqual(sentText.count, 0, "cmd+v with a clipboard image must consume the keystroke without pasting")
            XCTAssertEqual(sentKeys, [])
        }

        /// The cheap type probe can declare an image the handler cannot actually read; the paste then falls
        /// through to the text path rather than doing nothing.
        func testRemoteTerminalPasteFallsThroughToTextWhenImageHandlerDeclines() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentText: [(String, Bool)] = []
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.onPasteClipboardImage = { false }
            hostView.setAcceptsTerminalInput(true)
            hostView.setClipboardTextForTesting("clipboard payload")
            hostView.setClipboardHasImageForTesting(true)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let pasteButton = try XCTUnwrap(descendants(of: accessoryView, matching: UIButton.self).first { $0.accessibilityLabel == "Paste" })
            pasteButton.sendActions(for: .touchUpInside)

            XCTAssertEqual(sentText.count, 1)
            XCTAssertEqual(sentText.first?.0, "clipboard payload")
            XCTAssertEqual(sentText.first?.1, true)
        }

        /// A text-only clipboard must never reach the image handler: the probe gates it, so no paste
        /// prompt for image data is triggered on the common path.
        func testRemoteTerminalPasteWithoutClipboardImageSkipsImageHandler() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            var sentText: [(String, Bool)] = []
            var imageHandlerCallCount = 0
            hostView.onSendText = { text, asPaste in sentText.append((text, asPaste)) }
            hostView.onPasteClipboardImage = {
                imageHandlerCallCount += 1
                return true
            }
            hostView.setAcceptsTerminalInput(true)
            hostView.setClipboardTextForTesting("clipboard payload")
            hostView.setClipboardHasImageForTesting(false)

            let accessoryView = try XCTUnwrap(hostView.inputAccessoryView)
            let pasteButton = try XCTUnwrap(descendants(of: accessoryView, matching: UIButton.self).first { $0.accessibilityLabel == "Paste" })
            pasteButton.sendActions(for: .touchUpInside)

            XCTAssertEqual(imageHandlerCallCount, 0)
            XCTAssertEqual(sentText.count, 1)
            XCTAssertEqual(sentText.first?.0, "clipboard payload")
        }

        func testRemoteTerminalAccessoryJoystickRequiresDirectionalRelease() {
            let hostView = GhosttyRemoteTerminalHostView(frame: .zero)
            let bounds = CGRect(x: 0, y: 0, width: 46, height: 36)
            func direction(dx: CGFloat, dy: CGFloat) -> String? {
                hostView.accessoryToolbarJoystickDirectionForTesting(translationX: dx, translationY: dy)
            }
            func acceptsRelease(x: CGFloat, y: CGFloat) -> Bool {
                hostView.accessoryToolbarJoystickAcceptsReleaseForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }
            func acceptsActivation(x: CGFloat, y: CGFloat) -> Bool {
                hostView.accessoryToolbarJoystickAcceptsActivationForTesting(point: CGPoint(x: x, y: y), bounds: bounds)
            }

            // Direction comes from how far the finger slid since touch-down, not absolute position.
            XCTAssertNil(direction(dx: 0, dy: 0))
            XCTAssertNil(direction(dx: 16, dy: 0))
            XCTAssertEqual(direction(dx: 17, dy: 0), "right")
            XCTAssertEqual(direction(dx: -17, dy: 0), "left")
            XCTAssertEqual(direction(dx: 0, dy: -17), "up")
            XCTAssertEqual(direction(dx: 0, dy: 17), "down")
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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

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
                snapshot: snapshot(columns: 80, rows: 24, text: wideText), renderStateKey: "viewer|runtime=80x24|snapshot=80x24|interactive=0",
                fallbackText: "Waiting for terminal state…")

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
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
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
            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, 334, accuracy: 0.5)
            XCTAssertEqual(try XCTUnwrap(reportedViewports.last).rows, keyboardViewport.rows)

            let longSnapshot = promptAtBottomSnapshot(columns: 80, rows: fullViewport.rows + 20)
            hostView.update(
                snapshot: longSnapshot, renderStateKey: "viewer|runtime=80x\(longSnapshot.rows)|snapshot=80x\(longSnapshot.rows)|interactive=0",
                fallbackText: "Waiting for terminal state...")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let renderedSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let renderedText = GhosttyTerminalSnapshotLayout.plainText(for: renderedSnapshot)
            XCTAssertEqual(renderedSnapshot.rows, keyboardViewport.rows)
            XCTAssertTrue(renderedText.localizedStandardContains("shell %"), renderedText)
            XCTAssertFalse(renderedText.localizedStandardContains("SEQ 000000"), renderedText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewSettlesKeyboardViewportOnceAfterReplacingATransition() throws {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 393, height: 640))
            hostView.userInterfaceIdiomOverrideForTesting = .phone
            hostView.setAcceptsTerminalInput(true)
            hostView.setKeyboardOccludedHeightForTesting(0)

            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()
            let baselineViewport = hostView.viewportSizeForTesting()
            reportedViewports.removeAll()
            let rendersBeforeTransition = hostView.renderLatestSnapshotCallCountForTesting

            hostView.setSoftwareKeyboardVisible(false)
            let firstSettlement = try XCTUnwrap(hostView.keyboardViewportSettlementIDForTesting())
            hostView.setKeyboardOccludedHeightForTesting(180)
            hostView.layoutIfNeeded()

            XCTAssertTrue(reportedViewports.isEmpty, "an intermediate keyboard frame must not resize the remote terminal")
            XCTAssertEqual(
                hostView.renderLatestSnapshotCallCountForTesting, rendersBeforeTransition + 1, "the local surface must follow the keyboard layout")

            hostView.setSoftwareKeyboardVisible(true)
            let secondSettlement = try XCTUnwrap(hostView.keyboardViewportSettlementIDForTesting())
            XCTAssertNotEqual(firstSettlement, secondSettlement)
            hostView.setKeyboardOccludedHeightForTesting(260)
            hostView.layoutIfNeeded()

            XCTAssertTrue(reportedViewports.isEmpty, "the replacement transition must also suppress its interim viewport")
            XCTAssertEqual(hostView.renderLatestSnapshotCallCountForTesting, rendersBeforeTransition + 2)

            hostView.completeKeyboardViewportSettlementForTesting(id: firstSettlement)
            XCTAssertTrue(reportedViewports.isEmpty, "a cancelled transition must not report after its replacement")
            XCTAssertEqual(hostView.renderLatestSnapshotCallCountForTesting, rendersBeforeTransition + 2)

            hostView.completeKeyboardViewportSettlementForTesting(id: secondSettlement)
            XCTAssertEqual(reportedViewports.count, 1)
            let finalReport = try XCTUnwrap(reportedViewports.first)
            let settledViewport = hostView.viewportSizeForTesting()
            XCTAssertNotEqual(settledViewport.rows, baselineViewport.rows)
            XCTAssertEqual(finalReport.columns, settledViewport.columns)
            XCTAssertEqual(finalReport.rows, settledViewport.rows)
            XCTAssertEqual(hostView.renderLatestSnapshotCallCountForTesting, rendersBeforeTransition + 3)

            hostView.setKeyboardOccludedHeightForTesting(260)
            hostView.layoutIfNeeded()
            let restoredViewport = hostView.viewportSizeForTesting()
            let lastReportedViewport = try XCTUnwrap(reportedViewports.last)
            XCTAssertEqual(lastReportedViewport.columns, restoredViewport.columns, "ordinary layouts still report outside keyboard transitions")
            XCTAssertEqual(lastReportedViewport.rows, restoredViewport.rows, "ordinary layouts still report outside keyboard transitions")
            XCTAssertEqual(hostView.renderLatestSnapshotCallCountForTesting, rendersBeforeTransition + 4)
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

            XCTAssertEqual(hostView.visibleRenderBoundsForTesting().height, phoneBounds.height - 46, accuracy: 0.5)
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
                fallbackText: "Waiting for terminal state...")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=2",
                fallbackText: "Waiting for terminal state…")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=teardown",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            XCTAssertTrue(hostView.hasActiveSessionForTesting)

            let freeCompleted = expectation(description: "background free completed")
            let originalSessionFreeHandler = GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting
            // Gate the free handler on a semaphore so the "dismantle didn't block on it" assertion below is
            // checked while the handler is still provably in flight, instead of picking a duration long enough
            // that it's probably still running. Always released via defer so a failed assertion above can't
            // leave the handler's background thread blocked forever.
            let releaseFree = DispatchSemaphore(value: 0)
            defer { releaseFree.signal() }
            GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting = { _ in
                // Bounded wait: if prepareForDismantle() ever regresses to running this handler
                // synchronously, the test thread would otherwise block on its own gate forever;
                // the timeout turns that regression into a failed elapsed-time assertion instead.
                _ = releaseFree.wait(timeout: .now() + 30)
                freeCompleted.fulfill()
            }
            defer { GhosttyRemoteTerminalHostView.sessionFreeHandlerForTesting = originalSessionFreeHandler }

            let startedAt = Date()
            hostView.prepareForDismantle()
            let elapsed = Date().timeIntervalSince(startedAt)

            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)

            releaseFree.signal()
            wait(for: [freeCompleted], timeout: 30)

            window.isHidden = true
        }

        /// Applying a frame to the mirror copies the whole grid and blocks on the GPU, and the calls that
        /// reach it are mostly not about terminal content at all: SwiftUI re-runs `updateUIView` for any
        /// observed change (a title a coding agent rewrites many times a second is enough), and UIKit
        /// re-runs `layoutSubviews` for keyboard and layout reasons of its own. A frame the surface
        /// already holds must therefore cost nothing, while a frame that actually differs must still be
        /// applied.
        func testTheMirrorSkipsAFrameItAlreadyHoldsAndAppliesAChangedOne() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let renderStateKey = "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=identity"
            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "identity")
            defer { hostView.removeFromSuperview() }
            let appliesAfterMount = hostView.renderFrameApplyCountForTesting
            XCTAssertGreaterThan(appliesAfterMount, 0, "mounting has to put the first frame on the surface")

            // A layout pass carries no new frame.
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()
            XCTAssertEqual(hostView.renderFrameApplyCountForTesting, appliesAfterMount)

            // A title-only payload leaves the owner epoch's snapshot untouched, so the viewer re-pushes
            // exactly what it pushed before.
            hostView.update(snapshot: sampleSnapshot(), renderStateKey: renderStateKey, fallbackText: "Waiting for terminal state...")
            XCTAssertEqual(hostView.renderFrameApplyCountForTesting, appliesAfterMount, "a repeated frame must not be re-applied")

            hostView.update(snapshot: sampleSnapshotWithExclamation(), renderStateKey: renderStateKey, fallbackText: "Waiting for terminal state...")
            XCTAssertGreaterThan(hostView.renderFrameApplyCountForTesting, appliesAfterMount, "changed content must reach the surface")
        }

        func testTheMirrorRefreshesGeometryWithoutReapplyingAnUnchangedFrame() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 640))
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "geometry-growth")
            defer { hostView.removeFromSuperview() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let appliesAtOriginalGeometry = hostView.renderFrameApplyCountForTesting

            // Hiding the keyboard grows the view without changing the daemon snapshot. The surface
            // refreshes its retained state at the new geometry without resetting it from that frame.
            hostView.frame.size.height += 120
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()

            XCTAssertEqual(
                hostView.renderFrameApplyCountForTesting, appliesAtOriginalGeometry, "a geometry change must not re-apply an unchanged frame")
        }

        /// `TerminalViewerModel.updateOwnerRenderSnapshot` is the steady-streaming path: it keeps the
        /// owner epoch's `id` fixed and only swaps the snapshot it carries, unlike a fresh
        /// `beginOwnerRenderEpoch` which mints a new id. This pins `AppliedRenderFrameIdentity`'s
        /// `snapshot` field against that shape directly, calling `update(ownerEpoch:endedRender:fallbackText:)`
        /// with the same id twice: the fileprivate `update(snapshot:renderStateKey:fallbackText:)` test
        /// helper folds the snapshot into the id it mints, so it cannot exercise this path — every
        /// snapshot change there also changes the render key, which alone would still gate the re-apply
        /// even if `snapshot` were dropped from the identity.
        func testUpdateOwnerRenderSnapshotAppliesAChangedSnapshotUnderTheSameEpoch() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "same-epoch-snapshot-swap")
            defer { hostView.removeFromSuperview() }

            let fixedEpochID = "owner|same-epoch-snapshot-swap"
            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: fixedEpochID, bootstrapSnapshot: sampleSnapshot()),
                endedRender: nil, fallbackText: "Waiting for terminal state...")
            let appliesAfterFirstSnapshot = hostView.renderFrameApplyCountForTesting

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session", id: fixedEpochID, bootstrapSnapshot: sampleSnapshotWithExclamation()), endedRender: nil,
                fallbackText: "Waiting for terminal state...")
            XCTAssertGreaterThan(
                hostView.renderFrameApplyCountForTesting, appliesAfterFirstSnapshot,
                "a snapshot swap under the same owner epoch id must still reach the surface")
        }

        /// The shared mirror moves between terminal views, and an acquired surface still holds the cells
        /// the previous holder applied. A view that takes it back must re-apply its own frame even though
        /// nothing about that frame changed, or it renders the other session's pixels.
        ///
        /// This goes through the real handover rather than calling `surrenderSharedMirror()` directly on
        /// one view: doing that leaves `GhosttySharedTerminalMirror`'s own `holder` pointed at the view
        /// the whole time, so `acquire(for:...)`'s `holder === view` fast path (never having to park or
        /// hand the mirror back) is what a single-view version of this test would actually exercise —
        /// `reclaimSurrenderedSharedMirror()` clears the applied-frame identity on its own regardless of
        /// which path `acquire` takes, so a single-view test would pass even if `acquire`'s handover
        /// logic and `offerParkedMirrorToLatestSurrenderedHolder` were both broken. Mounting a second host
        /// view is what forces the mirror to actually leave the first view (`holder !== view` inside
        /// `acquire`) and actually come back through the park/offer path when the second one tears down.
        func testAReacquiredMirrorReAppliesTheFrameTheViewAlreadyHeld() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let firstView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "reapply-first")
            defer { firstView.removeFromSuperview() }
            let appliesBeforeSurrender = firstView.renderFrameApplyCountForTesting
            XCTAssertTrue(firstView.hasMirrorSurfaceForTesting)

            // A second view mounting takes the mirror over for real: `GhosttySharedTerminalMirror.acquire`
            // sees a different holder, parks `firstView` (clearing its applied-frame identity as a side
            // effect of the real handover, not of the test poking at it), and applies its own, different
            // frame.
            let secondView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "reapply-second")
            secondView.update(
                snapshot: sampleSnapshotWithExclamation(),
                renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=reapply-second-frame",
                fallbackText: "Waiting for terminal state...")
            XCTAssertFalse(firstView.hasMirrorSurfaceForTesting, "the mirror must actually leave the first view, not merely look surrendered")
            XCTAssertTrue(secondView.hasMirrorSurfaceForTesting)

            // Tearing the second view down parks the mirror and offers it to whoever is latched waiting
            // for it, which is `firstView` — the real path `offerParkedMirrorToLatestSurrenderedHolder`
            // exists for. `prepareForDismantle()` alone is enough (it is also what leaving the window
            // would trigger via `didMoveToWindow()`), so this does not also remove the view from its
            // superview and risk running the teardown twice.
            secondView.prepareForDismantle()

            XCTAssertTrue(firstView.hasMirrorSurfaceForTesting, "the mirror must come back to the view it was parked for")
            XCTAssertGreaterThan(
                firstView.renderFrameApplyCountForTesting, appliesBeforeSurrender,
                "the reacquired mirror still holds the second view's cells, so the first view's own frame must reach the surface again")
        }

        func testRemoteTerminalHostViewTeardownParksTheSharedMirrorWithoutBlocking() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "native-teardown")

            let startedAt = Date()
            hostView.prepareForDismantle()
            let elapsed = Date().timeIntervalSince(startedAt)

            XCTAssertLessThan(elapsed, 0.2)
            XCTAssertFalse(hostView.hasActiveSessionForTesting)
            XCTAssertFalse(hostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(hostView.hasRetainedSessionStandardInputWriteDescriptorForTesting)
            // The mirror survives the teardown parked and unattached rather than being leaked into a
            // per-teardown pile or freed on a user-facing path.
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            XCTAssertFalse(GhosttySharedTerminalMirror.shared.isSurfaceHostAttachedForTesting)
        }

        /// Opening a terminal and leaving it, over and over, is the navigation that used to charge the
        /// process a whole new mirror and IOSurface per visit. Every visit must land on the same
        /// native surface instead, so the footprint is bounded no matter how many sessions are opened.
        func testRepeatedTerminalVisitsReuseOneMirrorAndOneSurface() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            var surfaceIdentities: [UInt] = []
            for visit in 0..<4 {
                let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "revisit-\(visit)")
                surfaceIdentities.append(try XCTUnwrap(GhosttySharedTerminalMirror.shared.mirrorSurfaceIdentityForTesting))
                hostView.removeFromSuperview()

                XCTAssertFalse(hostView.hasMirrorSurfaceForTesting)
                XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            }

            XCTAssertEqual(Set(surfaceIdentities).count, 1)
        }

        /// A terminal view can mount while the outgoing one is still in the hierarchy — a session
        /// swap on the same route does exactly this. The newcomer takes the mirror over, so the two
        /// never render into the same surface, and only one mirror exists across the handover.
        func testMirrorMovesToTheTerminalViewThatMountsWhileAnotherHoldsIt() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let firstHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "handover-first")
            let secondHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "handover-second")

            XCTAssertTrue(secondHostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(firstHostView.hasMirrorSurfaceForTesting)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)

            // The surrendering view keeps its place in the hierarchy without clawing the mirror back,
            // so an outgoing view cannot trade it with the incoming one for the whole transition.
            // Both views are laid out repeatedly, which is what a navigation transition does to a
            // pair of terminals that are briefly on screen together.
            for _ in 0..<4 {
                firstHostView.setNeedsLayout()
                firstHostView.layoutIfNeeded()
                secondHostView.setNeedsLayout()
                secondHostView.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                XCTAssertTrue(secondHostView.hasMirrorSurfaceForTesting)
                XCTAssertFalse(firstHostView.hasMirrorSurfaceForTesting)
            }

            firstHostView.removeFromSuperview()
            secondHostView.removeFromSuperview()
        }

        /// A terminal presented over another — a sheet, a non-fullscreen cover, or a split layout —
        /// leaves the view it covers parented, so window re-entry never happens for it. When the
        /// newcomer goes away the mirror is parked and unheld, and it has to go back to the view that
        /// surrendered it instead of leaving that view permanently black.
        func testMirrorReturnsToTheSurrenderingViewWhenTheNewcomerGoesAwayWhileItStaysInTheWindow() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let coveredHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "reclaim-covered")
            let coveringHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "reclaim-covering")
            defer { coveredHostView.removeFromSuperview() }

            XCTAssertTrue(coveringHostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(coveredHostView.hasMirrorSurfaceForTesting)

            coveringHostView.removeFromSuperview()

            let deadline = Date().addingTimeInterval(2)
            while !coveredHostView.hasMirrorSurfaceForTesting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(coveredHostView.hasMirrorSurfaceForTesting)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            XCTAssertTrue(GhosttySharedTerminalMirror.shared.isSurfaceHostAttachedForTesting)
        }

        /// One update can both dismiss the terminal that covered another and mount a different one —
        /// closing a sheet while routing to another session does exactly this. The covered view is
        /// offered the parked mirror at the moment of that release, but the terminal that mounted in
        /// the same update is the one the user ends up looking at, so the hand-back must never end
        /// with the mirror taken off it.
        func testHandbackLeavesTheMirrorWithATerminalThatMountedDuringTheRelease() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let coveredHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "handback-covered")
            let coveringHostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "handback-covering")
            XCTAssertTrue(coveringHostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(coveredHostView.hasMirrorSurfaceForTesting)

            // The incoming terminal is mounted and the covering one is torn down in the same
            // uninterrupted run, so the incoming view is already asking for the mirror when the
            // release offers it back to the view underneath.
            let incomingHostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            viewController.view.addSubview(incomingHostView)
            incomingHostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()
            incomingHostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=handback-incoming",
                fallbackText: "Waiting for terminal state...")
            coveringHostView.removeFromSuperview()
            defer {
                coveredHostView.removeFromSuperview()
                incomingHostView.removeFromSuperview()
            }

            let deadline = Date().addingTimeInterval(2)
            while !incomingHostView.hasMirrorSurfaceForTesting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            // Settling past the acquisition is the point of the test: a hand-back that was decided
            // before the incoming view acquired would strip it a turn later.
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            XCTAssertTrue(incomingHostView.hasMirrorSurfaceForTesting)
            XCTAssertFalse(coveredHostView.hasMirrorSurfaceForTesting)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
        }

        /// Two sessions in succession share one surface, so the surface must stay hidden from the
        /// moment it is handed over until the new holder has drawn its own session onto it.
        func testRebindHidesTheSharedSurfaceUntilTheNewHolderRendersIt() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let firstHostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            let secondHostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            viewController.view.addSubview(firstHostView)
            viewController.view.addSubview(secondHostView)
            viewController.view.layoutIfNeeded()
            defer {
                firstHostView.removeFromSuperview()
                secondHostView.removeFromSuperview()
            }

            let mirror = GhosttySharedTerminalMirror.shared
            _ = try mirror.acquire(for: firstHostView, fontSize: .default, scaleFactor: 2)
            XCTAssertFalse(mirror.isSurfaceHostVisibleForTesting)

            mirror.revealSurface(from: firstHostView)
            XCTAssertTrue(mirror.isSurfaceHostVisibleForTesting)

            _ = try mirror.acquire(for: secondHostView, fontSize: .default, scaleFactor: 2)
            XCTAssertFalse(mirror.isSurfaceHostVisibleForTesting)
            XCTAssertTrue(mirror.isSurfaceHostAttachedForTesting)
            // The surface spans the whole holder, which is what the renderer sizes its target from.
            XCTAssertEqual(secondHostView.surfaceHostFrameForTesting(), secondHostView.bounds)

            // A late release from the view that already lost the mirror must not disturb the holder.
            mirror.release(from: firstHostView)
            XCTAssertTrue(mirror.isSurfaceHostAttachedForTesting)

            mirror.release(from: secondHostView)
            XCTAssertFalse(mirror.isSurfaceHostAttachedForTesting)
            XCTAssertFalse(mirror.isSurfaceHostVisibleForTesting)
        }

        /// Changing the font size retunes the live surface rather than building a second mirror, and
        /// the daemon still sees the resize as a new grid.
        func testChangingFontSizeRetunesTheSharedMirrorWithoutBuildingAnother() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            var reportedColumns: [Int] = []
            let hostView = try mountNativeMirrorHostView(in: viewController, window: window, screenKey: "font-size") { hostView in
                hostView.onViewportSizeChanged = { columns, _ in reportedColumns.append(columns) }
            }
            defer { hostView.removeFromSuperview() }

            let surfaceIdentity = try XCTUnwrap(GhosttySharedTerminalMirror.shared.mirrorSurfaceIdentityForTesting)
            let columnsAtDefaultSize = try XCTUnwrap(reportedColumns.last)

            hostView.setTerminalFontSize(.nine)

            XCTAssertEqual(GhosttySharedTerminalMirror.shared.liveMirrorCountForTesting, 1)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.appliedFontSizeForTesting, .nine)
            XCTAssertEqual(GhosttySharedTerminalMirror.shared.mirrorSurfaceIdentityForTesting, surfaceIdentity)
            XCTAssertGreaterThan(try XCTUnwrap(reportedColumns.last), columnsAtDefaultSize)
        }

        /// A cold open's pre-mirror layout pass must not report the `UIFont` estimate: the real
        /// surface (a few hundred ms later, once `scheduleMirrorAcquisitionIfNeeded`'s task actually
        /// acquires one) almost never agrees with it, which is what forces the daemon into a second,
        /// visible resize. With nothing cached for this (font size, scale) yet, the view has to wait
        /// for that surface rather than report a guess in the meantime.
        func testAnEstimateViewportIsSuppressedWhileMirrorAcquisitionIsImminent() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let originalCache = GhosttyRemoteTerminalHostView.cellMetricsCache
            GhosttyRemoteTerminalHostView.cellMetricsCache = GhosttyTerminalCellMetricsCache(
                defaults: try XCTUnwrap(UserDefaults(suiteName: "suppression-test-\(UUID().uuidString)")), storageKey: "cache", stamp: "test-stamp")
            defer { GhosttyRemoteTerminalHostView.cellMetricsCache = originalCache }

            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
            defer { hostView.removeFromSuperview() }
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds

            // Synchronous: layoutSubviews reports before the async acquisition task (scheduled from
            // renderLatestSnapshot, which nothing has called yet) has any chance to run.
            viewController.view.layoutIfNeeded()
            XCTAssertEqual(reportedViewports.count, 0, "the pre-mirror estimate must not reach onViewportSizeChanged")

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=suppression",
                fallbackText: "Waiting for terminal state...")
            viewController.view.layoutIfNeeded()
            XCTAssertEqual(reportedViewports.count, 0, "still nothing to report until a mirror actually exists")

            let deadline = Date().addingTimeInterval(2)
            while !hostView.hasMirrorSurfaceForTesting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(hostView.hasMirrorSurfaceForTesting)
            XCTAssertGreaterThan(reportedViewports.count, 0, "the surface-backed report must land once the mirror exists")
        }

        /// With the native mirror disabled (every other test in this file, and any view that never
        /// becomes entitled to the shared mirror in production), `isMirrorAcquisitionImminent` is
        /// always false, so the suppression gate never applies: the pre-mirror estimate reports
        /// exactly as it did before this gate existed.
        func testEstimateViewportReportsNormallyWithTheNativeMirrorDisabled() {
            XCTAssertFalse(GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting, "this test relies on setUp's default")
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
            defer { hostView.removeFromSuperview() }
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds

            viewController.view.layoutIfNeeded()
            XCTAssertGreaterThan(reportedViewports.count, 0, "a disabled native mirror must keep reporting the estimate synchronously")
        }

        /// Layer 1 (suppression) plus layer 2 (the cell metrics cache) together: a cache entry seeded
        /// for this view's (font size, scale) before the mirror is acquired lets the very first
        /// report already be the padding-correct predicted grid, instead of waiting on the surface.
        func testACachedCellSizeProducesAnImmediateAccuratePreMirrorReport() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let cache = GhosttyTerminalCellMetricsCache(
                defaults: try XCTUnwrap(UserDefaults(suiteName: "cache-hit-test-\(UUID().uuidString)")), storageKey: "cache", stamp: "test-stamp")
            let originalCache = GhosttyRemoteTerminalHostView.cellMetricsCache
            GhosttyRemoteTerminalHostView.cellMetricsCache = cache
            defer { GhosttyRemoteTerminalHostView.cellMetricsCache = originalCache }

            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let scale = Double(window.screen.scale)
            cache.recordCellPixelSize(fontSizePoints: TerminalFontSize.default.rawValue, scale: scale, width: 24, height: 51)
            let expectedPrediction = try XCTUnwrap(
                cache.predictedGrid(
                    fontSizePoints: TerminalFontSize.default.rawValue, scale: scale, renderBoundsWidth: viewController.view.bounds.width,
                    renderBoundsHeight: viewController.view.bounds.height))

            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
            defer { hostView.removeFromSuperview() }
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds

            viewController.view.layoutIfNeeded()

            XCTAssertFalse(hostView.hasMirrorSurfaceForTesting, "this assertion only means anything before the surface exists")
            let firstReport = try XCTUnwrap(reportedViewports.first)
            XCTAssertEqual(firstReport.columns, expectedPrediction.columns)
            XCTAssertEqual(firstReport.rows, expectedPrediction.rows)
        }

        /// Mounts a terminal host view with a live native mirror and waits until it holds one.
        private func mountNativeMirrorHostView(
            in viewController: UIViewController, window: UIWindow, screenKey: String, configure: (GhosttyRemoteTerminalHostView) -> Void = { _ in }
        ) throws -> GhosttyRemoteTerminalHostView {
            viewController.view.frame = window.bounds
            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            configure(hostView)
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=\(screenKey)",
                fallbackText: "Waiting for terminal state...")

            let deadline = Date().addingTimeInterval(2)
            while !hostView.hasMirrorSurfaceForTesting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(hostView.hasMirrorSurfaceForTesting)
            return hostView
        }

        /// A cold open has a window and nonzero bounds well before the first daemon snapshot arrives
        /// (the render pipeline is what delivers the snapshot in the first place). Acquisition only
        /// requires those two things (`isEntitledToSharedMirror`), not content, so it must happen even
        /// when a snapshot never comes. Before the fix, `scheduleMirrorAcquisitionIfNeeded()` was only
        /// reachable from `renderLatestSnapshot()`'s post-snapshot path, so a view that never receives a
        /// snapshot never acquired a mirror, and the open-screen hold this feeds never saw a viewport
        /// report until its own timeout.
        func testHostViewAcquiresTheMirrorBeforeAnySnapshotArrives() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            defer { hostView.removeFromSuperview() }
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            XCTAssertNil(hostView.capturedSnapshotForTesting(), "this test only means something before any content arrives")
            let deadline = Date().addingTimeInterval(2)
            while !hostView.hasMirrorSurfaceForTesting && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(hostView.hasMirrorSurfaceForTesting, "a view with a window and bounds must acquire the mirror even with no snapshot yet")
        }

        /// A mirror that fails to acquire (a genuine creation failure, not a timing race that resolves on
        /// its own) must not become an unbounded reschedule loop, and must not leave the view stuck
        /// suppressing viewport reports forever. Before the fix, `acquireMirrorIfNeeded()`'s catch branch
        /// only traced the failure: the view stayed entitled, so `scheduleMirrorAcquisitionIfNeeded()`'s
        /// own completion (`renderLatestSnapshot()`) rescheduled another acquisition attempt on every
        /// turn, and `isMirrorAcquisitionImminent` stayed true forever, suppressing the estimate-based
        /// report that is otherwise this view's only viewport source. Regression test for
        /// `didFailMirrorAcquisition`, which latches the failure so both stop.
        func testFailedMirrorAcquisitionStopsReschedulingAndResumesEstimateReporting() throws {
            GhosttyRemoteTerminalHostView.nativeMirrorEnabledForTesting = true
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController
            window.isHidden = false
            defer { window.isHidden = true }

            let hostView = GhosttyRemoteTerminalHostView(frame: viewController.view.bounds)
            hostView.forceMirrorAcquisitionFailureForTesting = true
            var reportedViewports: [(columns: Int, rows: Int)] = []
            hostView.onViewportSizeChanged = { columns, rows in reportedViewports.append((columns: columns, rows: rows)) }
            defer { hostView.removeFromSuperview() }
            viewController.view.addSubview(hostView)
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            // Let the acquisition task (and, pre-fix, whatever it keeps rescheduling) run for a while.
            let settleDeadline = Date().addingTimeInterval(1)
            while Date() < settleDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            XCTAssertFalse(hostView.hasMirrorSurfaceForTesting, "the forced failure must never produce a mirror")

            let callCountAfterSettling = hostView.renderLatestSnapshotCallCountForTesting
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            XCTAssertEqual(
                hostView.renderLatestSnapshotCallCountForTesting, callCountAfterSettling,
                "a persistent acquisition failure must stop rescheduling instead of looping renderLatestSnapshot")

            XCTAssertGreaterThan(
                reportedViewports.count, 0, "a view whose mirror can never exist must still deliver the estimate-based viewport report")
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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.setAcceptsTerminalInput(true)
            XCTAssertTrue(hostView.becomeFirstResponder())
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let unexpectedInitialPublication = expectation(description: "input readiness should not publish on callback install")
            unexpectedInitialPublication.isInverted = true
            hostView.onInputReadinessChanged = { _ in unexpectedInitialPublication.fulfill() }
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
                    snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=\(cycle)",
                    fallbackText: "Waiting for terminal state…")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

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
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: refreshedSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

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
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

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
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: ownerEpochID, bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state...")

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
                    sessionID: "test-session", id: "owner|initial-output-repair", bootstrapSnapshot: repairedSnapshot), endedRender: nil,
                fallbackText: "Waiting for terminal state...")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(snapshot: nil, renderStateKey: "status", fallbackText: "Current owner: Mac")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.setTerminalVisible(true)
            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

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

            hostView.onRenderedTextChanged = { text in if text.localizedStandardContains("hi") { initialRenderedExpectation.fulfill() } }

            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.onRenderedTextChanged = nil
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.onRenderedTextChanged = { text in if text.localizedStandardContains("hi!") { republishedRenderedExpectation.fulfill() } }
            hostView.update(
                snapshot: sampleSnapshotWithExclamation(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0|screen=1",
                fallbackText: "Waiting for terminal state…")

            wait(for: [initialRenderedExpectation], timeout: 2)

            hostView.setTerminalVisible(false)
            hostView.update(snapshot: nil, renderStateKey: "status", fallbackText: "Current owner: Mac")

            wait(for: [clearedRenderedExpectation], timeout: 2)
            XCTAssertEqual(renderedEvents.last, "")

            window.isHidden = true
        }

        func testRemoteTerminalHostViewEncodesPreciseScrollMods() {
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .changed)), Int32(0b0000_0111))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .ended)), Int32(0b0000_1001))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .cancelled)), Int32(0b0000_1011))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: true, momentumState: .possible)), Int32(0b0000_1101))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .ended)), Int32(0b0000_1000))
            XCTAssertEqual(Int32(GhosttyRemoteTerminalHostView.makeScrollMods(hasPreciseDeltas: false, momentumState: .possible)), Int32(0b0000_1100))
        }

        func testRemoteTerminalHostViewForwardsPreciseScrollMods() {
            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                sentScrolls.append((horizontal, vertical, scrollMods, pointerPosition))
            }

            XCTAssertTrue(
                hostView.debugSendScrollForTesting(
                    horizontal: 0, vertical: 8, location: CGPoint(x: 160, y: 120), hasPreciseDeltas: true, momentumState: .changed))

            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 8)
            XCTAssertEqual(sentScrolls.last?.scrollMods, Int32(0b0000_0111))
            XCTAssertEqual(sentScrolls.last?.pointerPosition, .init(x: 0.25, y: 0.25))
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
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)

            XCTAssertTrue(hostView.debugSendScrollForTesting(horizontal: 0, vertical: 1))

            let tinyScrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            XCTAssertEqual(GhosttyTerminalSnapshotLayout.plainText(for: tinyScrolledSnapshot), bottomText)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewTinyScrollDeltasForwardWithoutLocalViewportMutation() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrollCount = 0
            hostView.onSendScroll = { _, _, _, _ in sentScrollCount += 1 }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)

            for _ in 0..<20 { XCTAssertTrue(hostView.debugSendScrollForTesting(horizontal: 0, vertical: 1)) }

            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertEqual(scrolledText, bottomText)
            XCTAssertEqual(sentScrollCount, 20)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewForwardsScrollbackWithoutLocalViewportMutation() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                sentScrolls.append((horizontal, vertical, scrollMods, pointerPosition))
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let bottomSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let bottomText = GhosttyTerminalSnapshotLayout.plainText(for: bottomSnapshot)
            XCTAssertTrue(bottomText.localizedStandardContains("SEQ 000219"), bottomText)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0, vertical: 10_000, location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY))
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertEqual(scrolledText, bottomText)
            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 10_000)

            window.isHidden = true
        }

        func testRemoteTerminalHostViewDoesNotLocallyScrollAfterResizeChurn() throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            let viewController = UIViewController()
            window.rootViewController = viewController

            let hostView = GhosttyRemoteTerminalHostView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
            var sentScrolls: [(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)] = []
            hostView.onSendScroll = { horizontal, vertical, scrollMods, pointerPosition in
                sentScrolls.append((horizontal, vertical, scrollMods, pointerPosition))
            }
            viewController.view.addSubview(hostView)
            window.isHidden = false
            viewController.view.frame = window.bounds
            hostView.frame = viewController.view.bounds
            viewController.view.layoutIfNeeded()

            hostView.update(
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            hostView.update(
                snapshot: scrollbackSnapshot(lineCount: 220), renderStateKey: "viewer|runtime=6x4|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            hostView.frame = CGRect(x: 0, y: 0, width: 700, height: 420)
            viewController.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            let preScrollSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let preScrollText = GhosttyTerminalSnapshotLayout.plainText(for: preScrollSnapshot)

            let didScroll = hostView.debugSendScrollForTesting(
                horizontal: 0, vertical: 10_000, location: CGPoint(x: hostView.bounds.midX, y: hostView.bounds.midY))
            XCTAssertTrue(didScroll)

            RunLoop.main.run(until: Date().addingTimeInterval(0.4))

            let scrolledSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let scrolledText = GhosttyTerminalSnapshotLayout.plainText(for: scrolledSnapshot)
            XCTAssertEqual(scrolledText, preScrollText)
            XCTAssertEqual(sentScrolls.last?.horizontal, 0)
            XCTAssertEqual(sentScrolls.last?.vertical, 10_000)

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
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: "owner-epoch-1", bootstrapSnapshot: bootstrapSnapshot),
                endedRender: nil, fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            let outputSnapshot = try XCTUnwrap(hostView.capturedSnapshotForTesting())
            let outputText = GhosttyTerminalSnapshotLayout.plainText(for: outputSnapshot)
            XCTAssertTrue(outputText.localizedStandardContains("old-output-line"), outputText)

            hostView.update(
                ownerEpoch: GhosttyRemoteTerminalOwnerEpoch(
                    sessionID: "test-session", id: "owner-epoch-2", bootstrapSnapshot: refreshedBootstrapSnapshot), endedRender: nil,
                fallbackText: "Waiting for terminal state…")

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
                snapshot: sampleSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

            RunLoop.main.run(until: Date().addingTimeInterval(0.25))

            hostView.update(
                snapshot: promptSnapshot(), renderStateKey: "viewer|runtime=4x2|snapshot=4x2|interactive=0",
                fallbackText: "Waiting for terminal state…")

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
                abs(layer.frame.width - hostView.bounds.width) < 0.5 && abs(layer.frame.height - hostView.bounds.height) < 0.5
            })
        }

        private func sampleSnapshot() -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let characters = Array("hi".unicodeScalars)
            let cells: [GhosttyTerminalSnapshot.Cell] = [
                GhosttyTerminalSnapshot.Cell(codepoint: characters[0].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[1].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0), blank,
                blank, blank, blank, blank, blank,
            ]

            return GhosttyTerminalSnapshot(
                columns: 4, rows: 2, cursorColumn: 2, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26, cells: cells)
        }

        private func sampleSnapshotWithExclamation() -> GhosttyTerminalSnapshot {
            let blank = GhosttyTerminalSnapshot.Cell(codepoint: 0, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
            let characters = Array("hi!".unicodeScalars)
            let cells: [GhosttyTerminalSnapshot.Cell] = [
                GhosttyTerminalSnapshot.Cell(codepoint: characters[0].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[1].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0),
                GhosttyTerminalSnapshot.Cell(codepoint: characters[2].value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0), blank,
                blank, blank, blank, blank,
            ]

            return GhosttyTerminalSnapshot(
                columns: 4, rows: 2, cursorColumn: 3, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26, cells: cells)
        }

        private func promptSnapshot() -> GhosttyTerminalSnapshot { snapshot(columns: 8, rows: 2, text: "shell % ") }

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
                cells[cellIndex] = GhosttyTerminalSnapshot.Cell(codepoint: scalar.value, foregroundRGB: 0xF2F2F2, backgroundRGB: 0x1A1E26, flags: 0)
                cursorColumn += 1
            }

            return GhosttyTerminalSnapshot(
                columns: columns, rows: rows, cursorColumn: min(max(cursorColumn, 0), max(columns - 1, 0)),
                cursorRow: min(max(cursorRow, 0), max(rows - 1, 0)), cursorVisible: true, defaultForegroundRGB: 0xF2F2F2,
                defaultBackgroundRGB: 0x1A1E26, cells: cells)
        }

    }

    private func descendants<ViewType: UIView>(of view: UIView, matching type: ViewType.Type) -> [ViewType] {
        var matches: [ViewType] = []
        if let typedView = view as? ViewType { matches.append(typedView) }
        for subview in view.subviews { matches.append(contentsOf: descendants(of: subview, matching: type)) }
        return matches
    }

    extension GhosttyRemoteTerminalHostView {
        fileprivate func update(snapshot: GhosttyTerminalSnapshot?, renderStateKey: String, fallbackText: String) {
            let ownerEpoch: GhosttyRemoteTerminalOwnerEpoch?
            if snapshot != nil {
                let epochID = "owner|\(renderStateKey)|\(snapshotSignature(snapshot))"
                ownerEpoch = GhosttyRemoteTerminalOwnerEpoch(sessionID: "test-session", id: epochID, bootstrapSnapshot: snapshot)
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
