import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class SpacesMobileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testTerminalTakeOverFromList() throws { try runTerminalTakeOverScenario() }

    func testTerminalTakeOverAfterMacRetakeover() throws { try runTerminalTakeOverScenario() }

    func testTerminalTakeOverAfterTwoMacRetakeovers() throws { try runTerminalTakeOverScenario() }

    func testTerminalTakeOverRoundTripWithCommands() throws { try runTerminalTakeOverScenario() }

    func testTerminalTakeOverAcrossTwoSessionsFromList() throws { try runTerminalTakeOverScenario() }

    func testTerminalInterruptShowsFinalFrameAndKeepsSecondSessionLive() throws { try runTerminalInterruptFinalFrameScenario() }

    func testTerminalTakeOverReopenSameSessionFromList() throws { try runTerminalTakeOverScenario() }

    func testTerminalTapLocalImagePathOpensPreview() throws { try runTerminalLinkPreviewScenario() }

    func testWorkspaceDeleteWhileScrollingList() throws { try runWorkspaceBandRemovalWhileScrollingScenario(action: .delete) }

    func testWorkspaceHideWhileScrollingList() throws { try runWorkspaceBandRemovalWhileScrollingScenario(action: .hide) }

    func testTerminalRowRemovedWhileScrollingList() throws { try runTerminalRowRemovalWhileScrollingScenario() }

    func testAttachedAppConfigurationDoesNotRequireCertificateFingerprint() throws {
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        defer { try? FileManager.default.removeItem(at: configURL) }
        let payload: [String: Any] = [
            "sessionID": "session-1", "host": "127.0.0.1", "port": 47_847, "authToken": "token", "installationID": "installation",
            "attachToExistingApp": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: configURL)

        let configuration = try UITestConfiguration.load(environment: ["SPACES_MOBILE_UI_TEST_CONFIG_PATH": configURL.path])

        XCTAssertTrue(configuration.attachToExistingApp)
        XCTAssertEqual(configuration.certificateFingerprint, "")
    }

    private func runTerminalTakeOverScenario() throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = launchConfiguredApp(configuration)
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        try returnToTerminalList(in: app)
        if configuration.proceedTakeOverPath != nil { waitForMarkerIfNeeded(configuration.proceedTakeOverPath, timeout: 60) }
        try takeOverSessionFromList(
            in: app, configuration: configuration, sessionID: configuration.sessionID, timeout: 20, context: "initial takeover")

        captureScreenshot(app, name: "post-takeover-immediate", filePath: configuration.immediateScreenshotPath)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        captureScreenshot(app, name: "post-takeover-plus-2s", filePath: configuration.shortDelayScreenshotPath)
        guard waitForVisibleTerminalContentIfNeeded(in: app, configuration: configuration, context: "after initial takeover", timeout: 4) else {
            return
        }
        captureScreenshot(app, name: "post-takeover-plus-6s", filePath: configuration.longDelayScreenshotPath)
        if let secondarySessionID = configuration.secondarySessionID {
            try takeOverSessionsAcrossListCycles(
                in: app, configuration: configuration, sessionIDs: [secondarySessionID, configuration.sessionID, secondarySessionID])
            return
        }
        if configuration.scrollbackSwipeCount > 0 {
            performScrollback(in: app, configuration: configuration)
            guard waitForVisibleTerminalContentIfNeeded(in: app, configuration: configuration, context: "after scrollback", timeout: 4) else {
                return
            }
            captureScreenshot(app, name: "post-scrollback", filePath: configuration.finalScreenshotPath)
        }

        if let firstCommandRequestPath = configuration.firstCommandRequestPath {
            waitForMarkerIfNeeded(firstCommandRequestPath, timeout: 20)
            focusTerminalSurface(in: app)
            writeMarkerIfNeeded(configuration.firstCommandFocusedPath)
            waitForMarkerIfNeeded(configuration.firstCommandCompletedPath, timeout: 20)
            XCTAssertTrue(
                waitForOwnerReadyState(in: app, configuration: configuration, timeout: 1),
                "Owner-ready badge did not return promptly after first iOS command")
            assertOwnerReadyStable(in: app, configuration: configuration, duration: 1, context: "after first iOS command")
            guard waitForVisibleTerminalContentIfNeeded(in: app, configuration: configuration, context: "after first iOS command", timeout: 4) else {
                return
            }
            captureScreenshot(app, name: "post-ios-command-immediate", filePath: configuration.postFirstCommandScreenshotPath)
            writeMarkerIfNeeded(configuration.firstCommandObservedPath)
            if let secondCommandRequestPath = configuration.secondCommandRequestPath {
                waitForMarkerIfNeeded(secondCommandRequestPath, timeout: 20)
                focusTerminalSurface(in: app)
                writeMarkerIfNeeded(configuration.secondCommandFocusedPath)
                waitForMarkerIfNeeded(configuration.secondCommandCompletedPath, timeout: 20)
                XCTAssertTrue(
                    waitForOwnerReadyState(in: app, configuration: configuration, timeout: 1),
                    "Owner-ready badge did not return promptly after second iOS command")
                assertOwnerReadyStable(in: app, configuration: configuration, duration: 1, context: "after second iOS command")
                guard waitForVisibleTerminalContentIfNeeded(in: app, configuration: configuration, context: "after second iOS command", timeout: 4)
                else { return }
                captureScreenshot(app, name: "post-ios-second-command", filePath: configuration.postSecondCommandScreenshotPath)
                writeMarkerIfNeeded(configuration.secondCommandObservedPath)
            }
        }

        if let proceedFinishPath = configuration.proceedFinishPath {
            waitForMarkerIfNeeded(proceedFinishPath, timeout: 30)
            for attemptIndex in 0..<configuration.manualRetakeoverAttempts {
                guard tapButton(in: app, identifier: "terminal.takeover", fallbackLabel: "Take Over", timeout: 20) else {
                    XCTFail("Timed out waiting for Take Over button after Mac retakeover")
                    return
                }
                guard waitForOwnerState(in: app, configuration: configuration, timeout: 45) else {
                    XCTFail("Timed out waiting for owner state after mobile retakeover attempt \(attemptIndex + 1)")
                    return
                }
                XCTAssertTrue(
                    waitForOwnerReadyState(in: app, configuration: configuration, timeout: 5),
                    "Owner-ready badge did not return promptly after mobile retakeover attempt \(attemptIndex + 1)")
                assertOwnerReadyStable(
                    in: app, configuration: configuration, duration: 1, context: "after mobile retakeover attempt \(attemptIndex + 1)")
                guard
                    waitForVisibleTerminalContentIfNeeded(
                        in: app, configuration: configuration, context: "after mobile retakeover attempt \(attemptIndex + 1)", timeout: 4)
                else { return }
                writeMarkerIfNeeded(configuration.manualRetakeoverObservedPath(for: attemptIndex))
                if attemptIndex + 1 < configuration.manualRetakeoverAttempts {
                    waitForMarkerIfNeeded(configuration.manualRetakeoverContinuePath(for: attemptIndex), timeout: 30)
                }
            }
            if let finalMacRetakeoverRequestPath = configuration.finalMacRetakeoverRequestPath {
                waitForMarkerIfNeeded(finalMacRetakeoverRequestPath, timeout: 30)
                guard waitForButton(in: app, identifier: "terminal.takeover", fallbackLabel: "Take Over", timeout: 20) != nil else {
                    XCTFail("Timed out waiting for Take Over button after the final Mac retakeover")
                    return
                }
                captureScreenshot(app, name: "post-final-mac-retakeover", filePath: configuration.postFinalMacRetakeoverScreenshotPath)
                writeMarkerIfNeeded(configuration.finalMacRetakeoverObservedPath)
            }
            captureScreenshot(app, name: "post-mac-retakeover", filePath: configuration.finalScreenshotPath)
        }
    }

    private func runTerminalInterruptFinalFrameScenario() throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = launchConfiguredApp(configuration)
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        try returnToTerminalList(in: app)
        try takeOverSessionFromList(
            in: app, configuration: configuration, sessionID: configuration.sessionID, timeout: 20, context: "interrupt primary")
        guard waitForVisibleTerminalContentIfNeeded(in: app, configuration: configuration, context: "before interrupt", timeout: 8) else { return }
        XCTAssertNotNil(
            waitForRenderDump(configuration: configuration, timeout: 20) { dump in
                dump.sessionID == configuration.sessionID && dump.isOwner && dump.combinedText.contains(configuration.expectedInterruptedText)
            }, "The interrupted session did not render the expected pre-interrupt marker")

        try writeE2ECommandRequest(configuration: configuration, key: "ctrl+c")
        XCTAssertTrue(
            waitForE2EEvent(configuration: configuration, kind: "e2e_command_request_consumed", detailContains: "key=ctrl+c", timeout: 10),
            "The app did not consume the ctrl+c E2E key request")

        guard
            let endedDump = waitForRenderDump(
                configuration: configuration, timeout: 45,
                predicate: { dump in
                    dump.sessionID == configuration.sessionID && dump.renderMode == "ended" && dump.showsTerminalSurface && !dump.hasError
                        && dump.combinedText.contains(configuration.expectedInterruptedText)
                        && !dump.combinedText.localizedStandardContains("final render was available")
                })
        else {
            XCTFail("Timed out waiting for the interrupted session final render")
            return
        }
        XCTAssertTrue(endedDump.renderStateKey.hasPrefix("ended|"), "Ended render used an unexpected render state key: \(endedDump)")
        XCTAssertFalse(app.buttons["terminal.takeover"].exists, "Ended sessions should not show Take Over")
        copyLatestRenderDump(configuration: configuration, to: configuration.interruptedRenderDumpPath)
        captureScreenshot(app, name: "post-interrupt-final-frame", filePath: configuration.postInterruptScreenshotPath)

        guard let secondarySessionID = configuration.secondarySessionID else { return }
        try returnToTerminalList(in: app)
        try takeOverSessionFromList(
            in: app, configuration: configuration, sessionID: secondarySessionID, timeout: 20, context: "post-interrupt secondary")
        let secondaryDetail = app.descendants(matching: .any)["terminal.detail.\(secondarySessionID)"]
        XCTAssertTrue(secondaryDetail.exists, "Secondary terminal detail disappeared after primary interrupt")
        XCTAssertFalse(app.staticTexts["This terminal session ended before a final render was available."].exists)
        XCTAssertFalse(app.staticTexts["The Device API request timed out."].exists)
        if !configuration.expectedSecondaryText.isEmpty {
            XCTAssertNotNil(
                waitForRenderDump(configuration: configuration, timeout: 20) { dump in
                    dump.sessionID == secondarySessionID && dump.renderMode != "ended"
                        && dump.combinedText.contains(configuration.expectedSecondaryText)
                }, "The secondary session did not render the expected post-interrupt marker")
        }
        captureScreenshot(app, name: "post-interrupt-secondary-live", filePath: configuration.finalScreenshotPath)
    }

    private func runTerminalLinkPreviewScenario() throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = launchConfiguredApp(configuration)
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        try takeOverSessionFromList(
            in: app, configuration: configuration, sessionID: configuration.sessionID, timeout: 20, context: "terminal link preview")
        let linkText = configuration.terminalLinkText
        XCTAssertFalse(linkText.isEmpty, "Missing terminal link text in UI test configuration")
        XCTAssertTrue(tapTerminalText(linkText, in: app, configuration: configuration, timeout: 20), "Unable to tap terminal text \(linkText)")
        XCTAssertTrue(
            waitForE2EEvent(configuration: configuration, kind: "open_link", detailContains: linkText, timeout: 10),
            "The terminal did not report opening \(linkText)")
        XCTAssertTrue(
            waitForLinkPreview(in: app, configuration: configuration, title: configuration.expectedLinkPreviewTitle, timeout: 20),
            "The terminal link preview did not appear for \(linkText). \(previewStateDescription(configuration: configuration))")
        captureScreenshot(app, name: "terminal-link-preview", filePath: configuration.linkPreviewScreenshotPath)
    }

    // MARK: - Workspace removal while scrolling

    private enum WorkspaceBandRemovalAction: String {
        case delete
        case hide
    }

    /// Permanent regression coverage: removing a workspace band while the list is being scrolled must not
    /// crash the list and must actually remove the workspace. A delete takes seconds on the daemon — the
    /// band is marked as deleting for that whole window and leaves the list only when the refreshed
    /// overview drops the workspace — so the scroll keeps the list moving across the publish that removes
    /// it, which is where the list's batch update has to stay consistent.
    private func runWorkspaceBandRemovalWhileScrollingScenario(action: WorkspaceBandRemovalAction) throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = launchConfiguredApp(configuration)
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let workspaceID = configuration.targetWorkspaceID
        XCTAssertFalse(workspaceID.isEmpty, "Missing targetWorkspaceID in the UI test configuration")

        let band = app.buttons["workspace.band.\(workspaceID)"]
        XCTAssertTrue(band.waitForExistence(timeout: 40), "Workspace band \(workspaceID) never appeared in the Spaces list")

        let actionIdentifier = "workspace.\(action.rawValue).\(workspaceID)"
        let actionLabel = action == .delete ? "Delete" : "Hide"
        guard openBandAction(actionIdentifier, label: actionLabel, band: band, in: app) else {
            captureScreenshot(app, name: "workspace-band-actions-missing", filePath: configuration.immediateScreenshotPath)
            XCTFail("Swipe action \(actionIdentifier) never became available")
            return
        }

        let confirmedAt: Date
        switch action {
        case .delete:
            // Identifier-only: the swipe action behind the sheet also reads "Delete", and a label match
            // would re-fire it instead of confirming.
            guard tapButton(in: app, identifier: "workspace.delete.confirm", fallbackLabel: "workspace.delete.confirm", timeout: 15) else {
                captureScreenshot(app, name: "workspace-delete-confirm-missing", filePath: configuration.immediateScreenshotPath)
                XCTFail("The delete confirmation sheet never offered a confirm button")
                return
            }
            confirmedAt = Date()
        case .hide:
            // The hide dialog's confirm label depends on whether the workspace is running.
            let confirmed =
                tapButton(in: app, identifier: "Stop and Hide", fallbackLabel: "Stop and Hide", timeout: 6)
                || tapButton(in: app, identifier: "Hide", fallbackLabel: "Hide", timeout: 6)
            guard confirmed else {
                captureScreenshot(app, name: "workspace-hide-confirm-missing", filePath: configuration.immediateScreenshotPath)
                XCTFail("The hide confirmation dialog never offered a confirm button")
                return
            }
            confirmedAt = Date()
        }

        // Scroll continuously across the whole mutation window. The removal publishes somewhere inside it,
        // so the diff always lands while the collection view is mid-scroll.
        let scrollDeadline = confirmedAt.addingTimeInterval(configuration.removalScrollSeconds)
        var inverted = false
        var connectionErrorAlerts = 0
        while Date() < scrollDeadline {
            guard app.state == .runningForeground else {
                XCTFail(
                    "The app stopped running while scrolling during the workspace \(action.rawValue). "
                        + "state=\(app.state.rawValue) elapsed=\(Date().timeIntervalSince(confirmedAt))s")
                return
            }
            if dismissConnectionErrorAlertIfPresent(in: app) { connectionErrorAlerts += 1 }
            scrollList(in: app, duration: 0.0, startInverted: inverted)
            inverted.toggle()
        }

        XCTAssertEqual(app.state, .runningForeground, "The app was not running in the foreground after the scroll window")
        if dismissConnectionErrorAlertIfPresent(in: app) { connectionErrorAlerts += 1 }

        // The band stays on screen (marked as deleting) for the whole mutation, so it disappearing is the
        // workspace actually leaving the list rather than the mark being applied.
        let removalDeadline = Date().addingTimeInterval(60)
        while Date() < removalDeadline, band.exists {
            guard app.state == .runningForeground else {
                XCTFail("The app stopped running while waiting for the workspace band to disappear")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if dismissConnectionErrorAlertIfPresent(in: app) { connectionErrorAlerts += 1 }
        }
        XCTAssertFalse(
            band.exists,
            "Workspace band \(workspaceID) never disappeared after the \(action.rawValue). "
                + "connectionErrorAlerts=\(connectionErrorAlerts) (a non-zero count means the device went unreachable, "
                + "so the mutation itself may have failed rather than the list having kept the band)")

        captureScreenshot(app, name: "workspace-\(action.rawValue)-after-scroll", filePath: configuration.finalScreenshotPath)
    }

    /// Permanent regression coverage for the other way the Spaces list loses a row: a terminal session
    /// ending takes its runtime row out from under the workspace band, which stays listed. That is a row
    /// leaving a band that survives — the shape a workspace delete deliberately avoids — and it happens
    /// without the user doing anything, so it has to hold up under a scroll too. The lane ends the session
    /// from the daemon side while this test keeps the list moving.
    private func runTerminalRowRemovalWhileScrollingScenario() throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = launchConfiguredApp(configuration)
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let workspaceID = configuration.targetWorkspaceID
        XCTAssertFalse(workspaceID.isEmpty, "Missing targetWorkspaceID in the UI test configuration")

        let band = app.buttons["workspace.band.\(workspaceID)"]
        XCTAssertTrue(band.waitForExistence(timeout: 40), "Workspace band \(workspaceID) never appeared in the Spaces list")
        let row = app.buttons["terminal.row.\(configuration.sessionID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 40), "Terminal row for session \(configuration.sessionID) never appeared under its workspace")

        // Scroll for the whole window rather than stopping when the row goes: the lane ends the session on
        // a delay, and a list cell that has scrolled out of the collection view's rendered range reports as
        // absent, so the row vanishing mid-scroll says nothing on its own. Surviving the scroll is what is
        // being measured here, and it is measured for the whole window.
        var connectionErrorAlerts = 0
        var inverted = false
        let deadline = Date().addingTimeInterval(configuration.terminalRowRemovalTimeoutSeconds)
        while Date() < deadline {
            guard app.state == .runningForeground else {
                XCTFail("The app stopped running while scrolling as the terminal row was removed. state=\(app.state.rawValue)")
                return
            }
            if dismissConnectionErrorAlertIfPresent(in: app) { connectionErrorAlerts += 1 }
            scrollList(in: app, duration: 0.0, startInverted: inverted)
            inverted.toggle()
        }

        XCTAssertEqual(app.state, .runningForeground, "The app was not running in the foreground after the terminal row was removed")

        // Settle the list back at the top so both checks below are made against rendered cells rather than
        // against whatever the scroll happened to leave on screen.
        for _ in 0..<10 { scrollContainer(in: app).swipeDown(velocity: .fast) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        XCTAssertFalse(
            row.exists, "Terminal row for session \(configuration.sessionID) never disappeared. connectionErrorAlerts=\(connectionErrorAlerts)")
        // The band is the point: the row left a section that had to survive it.
        XCTAssertTrue(band.exists, "Workspace band \(workspaceID) disappeared along with its terminal row")
        captureScreenshot(app, name: "session-end-after-scroll", filePath: configuration.finalScreenshotPath)
    }

    /// Clears the connection-error alert if the app raised one, so the scroll can carry on, and reports
    /// whether it had to.
    ///
    /// Removing a workspace makes the daemon stop it and tear its worktree down, and while it is busy an
    /// overview poll can time out for long enough that the app reports the device unreachable. That says
    /// nothing about what this scenario tests — the list surviving a workspace being removed underneath a
    /// scroll — but an alert over the list blocks every gesture, and XCUITest's own interruption handling
    /// then fails the swipe instead of scrolling. The caller carries the fact into its failure message
    /// rather than dropping it, because the same alert is also how a mutation that genuinely failed shows
    /// up, and that is worth telling apart from a band that stayed for any other reason.
    private func dismissConnectionErrorAlertIfPresent(in app: XCUIApplication) -> Bool {
        let alert = app.alerts["Connection Error"]
        guard alert.exists else { return false }
        alert.buttons["OK"].tap()
        return true
    }

    /// One scroll pass. `duration` of 0 performs a single swipe; a positive duration keeps swiping for
    /// that long. Alternating direction keeps the list moving instead of parking at an edge.
    private func scrollList(in app: XCUIApplication, duration: TimeInterval, startInverted: Bool) {
        let deadline = Date().addingTimeInterval(duration)
        var inverted = startInverted
        repeat {
            let target = scrollContainer(in: app)
            if inverted { target.swipeDown(velocity: .fast) } else { target.swipeUp(velocity: .fast) }
            inverted.toggle()
        } while Date() < deadline
    }

    /// Brings the element into the middle band of the screen. A row parked under the translucent
    /// navigation bar reports as hittable but swallows the swipe, so vertical position matters as much
    /// as existence here.
    private func positionElementForSwipe(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let appFrame = app.frame
        let comfortableTop = appFrame.minY + appFrame.height * 0.28
        let comfortableBottom = appFrame.minY + appFrame.height * 0.72
        var inverted = false
        while Date() < deadline {
            if element.exists, element.isHittable {
                let midY = element.frame.midY
                if midY >= comfortableTop, midY <= comfortableBottom { return true }
                // Drag the content the short distance that moves the row into the comfortable band.
                let towardBottom = midY < comfortableTop
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardBottom ? 0.35 : 0.65))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardBottom ? 0.55 : 0.45))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                let target = scrollContainer(in: app)
                if inverted { target.swipeDown() } else { target.swipeUp() }
                inverted.toggle()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return element.exists && element.isHittable
    }

    /// Opens the band's trailing swipe actions and taps one. The swipe is retried because a list that is
    /// still settling (or a row that drifted under the navigation bar) can swallow the gesture entirely.
    private func openBandAction(_ identifier: String, label: String, band: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<5 {
            guard positionElementForSwipe(band, in: app, timeout: 20) else { continue }
            band.swipeLeft()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if tapButton(in: app, identifier: identifier, fallbackLabel: label, timeout: 3) { return true }
            // Close a half-open swipe before retrying so the next gesture starts from a settled row.
            band.swipeRight()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        // Long press opens the same Hide/Delete pair as the swipe; the real-device report reached Delete
        // either way, so this keeps the reproduction going when the gesture recognizer refuses the swipe.
        if positionElementForSwipe(band, in: app, timeout: 10) {
            band.press(forDuration: 1.2)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if tapButton(in: app, identifier: identifier, fallbackLabel: label, timeout: 5) { return true }
        }
        return false
    }

    private func scrollContainer(in app: XCUIApplication) -> XCUIElement {
        let collectionView = app.collectionViews.firstMatch
        if collectionView.exists { return collectionView }
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists { return scrollView }
        return app
    }

    private func launchConfiguredApp(_ configuration: UITestConfiguration) -> XCUIApplication {
        if configuration.attachToExistingApp {
            let app = XCUIApplication(bundleIdentifier: configuration.bundleID)
            if app.state != .notRunning {
                app.activate()
                XCTAssertTrue(waitForRunningApp(app, timeout: 20), "Timed out waiting for attached app \(configuration.bundleID) to become active")
                return app
            }
        }

        // The primary target launch path reliably carries launchEnvironment into
        // cold starts; bundle-identifier launches can come up unconfigured.
        let app = XCUIApplication()
        applyConfiguredLaunchEnvironment(to: app, configuration: configuration)
        app.launch()
        return app
    }

    private func applyConfiguredLaunchEnvironment(to app: XCUIApplication, configuration: UITestConfiguration) {
        // DEBUG-only paywall bypass so cold-start UI test launches reach the app shell without an
        // active subscription. Release builds ignore the flag.
        app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1"
        app.launchEnvironment["SPACES_MOBILE_TEST_HOST"] = configuration.host
        app.launchEnvironment["SPACES_MOBILE_TEST_PORT"] = String(configuration.port)
        app.launchEnvironment["SPACES_MOBILE_TEST_AUTH_TOKEN"] = configuration.authToken
        app.launchEnvironment["SPACES_MOBILE_TEST_CERTIFICATE_FINGERPRINT"] = configuration.certificateFingerprint
        app.launchEnvironment["SPACES_MOBILE_TEST_INSTALLATION_ID"] = configuration.installationID
        if let deviceSeedJSON = configuration.deviceSeedJSON { app.launchEnvironment["SPACES_MOBILE_TEST_DEVICE_SEED_JSON"] = deviceSeedJSON }
        app.launchEnvironment["SPACES_MOBILE_E2E_TARGET_SESSION_ID"] = configuration.sessionID
        if let secondarySessionID = configuration.secondarySessionID {
            app.launchEnvironment["SPACES_MOBILE_E2E_SECONDARY_SESSION_ID"] = secondarySessionID
        }
        if let renderDumpPath = configuration.renderDumpPath { app.launchEnvironment["SPACES_MOBILE_E2E_RENDER_DUMP_PATH"] = renderDumpPath }
        if let eventLogPath = configuration.eventLogPath { app.launchEnvironment["SPACES_MOBILE_E2E_EVENT_LOG_PATH"] = eventLogPath }
    }

    private func waitForButton(in app: XCUIApplication, identifier: String, fallbackLabel: String, timeout: TimeInterval) -> XCUIElement? {
        waitForElement(primary: app.buttons[identifier], fallback: app.buttons[fallbackLabel], timeout: timeout)
    }

    private func tapButton(in app: XCUIApplication, identifier: String, fallbackLabel: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let candidates = [
                app.buttons[identifier], app.descendants(matching: .any)[identifier], app.buttons[fallbackLabel],
                app.descendants(matching: .any)[fallbackLabel],
            ]
            for candidate in candidates where candidate.exists {
                if candidate.isHittable {
                    candidate.tap()
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func focusTerminalSurface(in app: XCUIApplication) {
        let terminalSurface = app.otherElements["terminal.surface"]
        if terminalSurface.waitForExistence(timeout: 2) { terminalSurface.tap() }
    }

    private func waitForVisibleTerminalContentIfNeeded(
        in app: XCUIApplication, configuration: UITestConfiguration, context: String, timeout: TimeInterval
    ) -> Bool {
        let requiredInkBands = configuration.minimumVisibleTerminalInkBands
        let maximumTopBlankRatio = configuration.maximumTerminalTopBlankRatio
        guard requiredInkBands > 0 || maximumTopBlankRatio > 0 else { return true }

        let deadline = Date().addingTimeInterval(timeout)
        var lastMetrics: TerminalSurfaceInkMetrics?
        var lastScreenshot: XCUIScreenshot?
        while Date() < deadline {
            let surface = terminalSurfaceElement(in: app)
            let screenshot = surface?.screenshot() ?? app.screenshot()
            lastScreenshot = screenshot
            if let metrics = Self.terminalSurfaceInkMetrics(from: screenshot.pngRepresentation, isFullAppScreenshot: surface == nil) {
                lastMetrics = metrics
                let hasEnoughInk = requiredInkBands <= 0 || metrics.inkBands >= requiredInkBands
                let hasAcceptableTopBlank =
                    maximumTopBlankRatio <= 0
                    || metrics.firstInkRow.map { Double($0) / Double(max(metrics.height, 1)) <= maximumTopBlankRatio } == true
                if hasEnoughInk, hasAcceptableTopBlank { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.name = "terminal-surface-visible-content-failure-\(context)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTFail(
            "Terminal surface did not visibly render enough content \(context). "
                + "requiredInkBands=\(requiredInkBands) maximumTopBlankRatio=\(maximumTopBlankRatio) "
                + "lastMetrics=\(String(describing: lastMetrics))")
        return false
    }

    private func terminalSurfaceElement(in app: XCUIApplication) -> XCUIElement? {
        let surface = app.otherElements["terminal.surface"].firstMatch
        guard surface.exists, surface.frame.width > 1, surface.frame.height > 1 else { return nil }
        return surface
    }

    private func tapTerminalText(_ target: String, in app: XCUIApplication, configuration: UITestConfiguration, timeout: TimeInterval) -> Bool {
        guard
            let dump = waitForRenderDump(
                configuration: configuration, timeout: timeout,
                predicate: { dump in
                    isOwnerReady(dump, expectedSessionID: configuration.sessionID) && terminalTextContains(target, in: dump.renderedText)
                })
        else { return false }
        let lines = dump.renderedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let columns = dump.viewportColumns, columns > 0 else { return false }
        let configuredRows = dump.viewportRows ?? lines.count
        let rows = min(max(configuredRows, 1), max(lines.count, 1))
        guard let tapLocation = terminalTextTapLocation(target, lines: lines, rows: rows, columns: columns) else { return false }
        let normalizedX = min(max(tapLocation.x / Double(columns), 0.01), 0.99)
        let normalizedY = min(max((Double(tapLocation.row) + 0.5) / Double(rows), 0.01), 0.99)
        if let surface = terminalSurfaceElement(in: app) {
            surface.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY)).tap()
            return true
        }
        return tapTerminalSurfaceFallback(in: app, configuration: configuration, normalizedX: normalizedX, normalizedY: normalizedY)
    }

    private func terminalTextContains(_ target: String, in renderedText: String) -> Bool {
        if renderedText.contains(target) { return true }
        let lines = renderedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return terminalTextTapLocation(target, lines: lines, rows: lines.count, columns: 1_000) != nil
    }

    private func terminalTextTapLocation(_ target: String, lines: [String], rows: Int, columns: Int) -> (row: Int, x: Double)? {
        for (row, line) in lines.enumerated() where row < rows {
            guard let range = line.range(of: target) else { continue }
            let column = line.distance(from: line.startIndex, to: range.lowerBound)
            let targetColumns = max(line.distance(from: range.lowerBound, to: range.upperBound), 1)
            let tapColumn = min(Double(column) + Double(targetColumns) / 2, Double(columns) - 0.5)
            return (row: row, x: tapColumn)
        }

        for startRow in 0..<rows {
            var joined = ""
            var segments: [(row: Int, start: Int, length: Int)] = []
            for row in startRow..<rows {
                let line = row < lines.count ? lines[row] : ""
                segments.append((row: row, start: joined.count, length: line.count))
                joined += line
                if let range = joined.range(of: target) {
                    let targetStart = joined.distance(from: joined.startIndex, to: range.lowerBound)
                    let targetEnd = joined.distance(from: joined.startIndex, to: range.upperBound)
                    for segment in segments where segment.length > 0 {
                        let segmentStart = segment.start
                        let segmentEnd = segment.start + segment.length
                        let overlapStart = max(targetStart, segmentStart)
                        let overlapEnd = min(targetEnd, segmentEnd)
                        guard overlapStart < overlapEnd else { continue }
                        let column = overlapStart - segmentStart + max((overlapEnd - overlapStart) / 2, 0)
                        return (row: segment.row, x: min(Double(column) + 0.5, Double(columns) - 0.5))
                    }
                    return nil
                }
                if joined.count > target.count + 1_000 { break }
            }
        }
        return nil
    }

    private func tapTerminalSurfaceFallback(in app: XCUIApplication, configuration: UITestConfiguration, normalizedX: Double, normalizedY: Double)
        -> Bool
    {
        let appFrame = app.frame
        guard appFrame.width > 1, appFrame.height > 1 else { return false }

        let terminalTextView = app.textViews.firstMatch
        var frame =
            terminalTextView.exists && terminalTextView.frame.width > 1 && terminalTextView.frame.height > 1 ? terminalTextView.frame : appFrame
        if frame == appFrame {
            let ownerBadge = app.otherElements["terminal.ownerBadge"]
            let ownerText = app.staticTexts["Owner"]
            let chromeBottom = [ownerBadge, ownerText].filter { $0.exists && $0.frame.height > 1 }.map(\.frame.maxY).max()
            let terminalTop = max(chromeBottom.map { $0 + 8 } ?? (frame.minY + 48), frame.minY)
            if terminalTop < frame.maxY - 1 { frame = CGRect(x: frame.minX, y: terminalTop, width: frame.width, height: frame.maxY - terminalTop) }
        }

        guard frame.width > 1, frame.height > 1 else { return false }
        let point = CGPoint(x: frame.minX + CGFloat(normalizedX) * frame.width, y: frame.minY + CGFloat(normalizedY) * frame.height)
        let offset = CGVector(dx: point.x - appFrame.minX, dy: point.y - appFrame.minY)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(offset).tap()
        return true
    }

    private func waitForLinkPreview(in app: XCUIApplication, configuration: UITestConfiguration, title: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasVisibleLinkPreview(in: app, title: title) { return true }
            if let dump = latestRenderDump(configuration: configuration) {
                if dump.hasLinkPreview(title: title, artifactKind: "image") { return true }
                if dump.hasLinkPreviewError, !hasVisibleLinkPreview(in: app, title: title) { return false }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if hasVisibleLinkPreview(in: app, title: title) { return true }
        guard let dump = latestRenderDump(configuration: configuration) else { return false }
        return dump.hasLinkPreview(title: title, artifactKind: "image")
    }

    private func hasVisibleLinkPreview(in app: XCUIApplication, title: String) -> Bool {
        app.descendants(matching: .any)["terminal.linkPreview"].exists || (!title.isEmpty && app.navigationBars[title].exists)
            || app.buttons["Open In"].exists
    }

    private func previewStateDescription(configuration: UITestConfiguration) -> String {
        guard let dump = latestRenderDump(configuration: configuration) else { return "No render dump was available." }
        if let error = dump.linkPreviewErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return "Preview error: \(error)"
        }
        return
            "Latest preview state: preparing=\(dump.isPreparingLinkPreview) title=\(dump.linkPreviewTitle ?? "") artifactKind=\(dump.linkPreviewArtifactKind ?? "")."
    }

    private static func terminalSurfaceInkMetrics(from pngData: Data, isFullAppScreenshot: Bool) -> TerminalSurfaceInkMetrics? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let firstRow = isFullAppScreenshot ? Int(Double(height) * 0.14) : 0
        let lastRow = isFullAppScreenshot ? max(firstRow, Int(Double(height) * 0.88)) : height
        let rowInkThreshold = max(3, width / 120)
        var brightPixels = 0
        var inkRows = 0
        var inkBands = 0
        var firstInkRow: Int?
        var previousRowHadInk = false
        for y in firstRow..<lastRow {
            var rowBrightPixels = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let alpha = Int(pixels[offset + 3])
                let luminance = (299 * red + 587 * green + 114 * blue) / 1000
                if alpha > 20, luminance > 70 { rowBrightPixels += 1 }
            }
            brightPixels += rowBrightPixels
            let rowHasInk = rowBrightPixels > rowInkThreshold
            if rowHasInk {
                if firstInkRow == nil { firstInkRow = y - firstRow }
                inkRows += 1
                if !previousRowHadInk { inkBands += 1 }
            }
            previousRowHadInk = rowHasInk
        }
        return TerminalSurfaceInkMetrics(
            width: width, height: lastRow - firstRow, brightPixels: brightPixels, inkRows: inkRows, inkBands: inkBands, firstInkRow: firstInkRow)
    }

    private func takeOverSessionsAcrossListCycles(in app: XCUIApplication, configuration: UITestConfiguration, sessionIDs: [String]) throws {
        for (index, sessionID) in sessionIDs.enumerated() {
            try returnToTerminalList(in: app)
            try takeOverSessionFromList(in: app, configuration: configuration, sessionID: sessionID, timeout: 20, context: "list cycle \(index + 1)")
        }
        captureScreenshot(app, name: "post-second-session-takeover", filePath: configuration.finalScreenshotPath)
    }

    private func returnToTerminalList(in app: XCUIApplication) throws {
        if isTerminalListVisible(in: app) { return }

        if let backControl = waitForElement(
            primary: app.buttons["terminal.back"], fallback: app.descendants(matching: .any)["terminal.back"], timeout: 4)
        {
            backControl.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.11)).tap()
        }
        XCTAssertTrue(waitForRunningApp(app, timeout: 5), "App stopped running after returning to the terminal list")
        XCTAssertTrue(waitForTerminalList(in: app, timeout: 8), "Timed out returning to the terminal list")
    }

    private func waitForTerminalList(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isTerminalListVisible(in: app) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func isTerminalListVisible(in app: XCUIApplication) -> Bool {
        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH %@", "terminal.row.")
        return app.buttons.matching(rowPredicate).firstMatch.exists
    }

    private func revealTerminalRow(_ row: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let scrollView = app.scrollViews.firstMatch
        while Date() < deadline {
            if row.exists, row.isEnabled, row.isHittable { return true }
            if scrollView.exists { scrollView.swipeUp() } else { app.swipeUp() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return row.exists && row.isEnabled && row.isHittable
    }

    private func takeOverSessionFromList(
        in app: XCUIApplication, configuration: UITestConfiguration, sessionID: String, timeout: TimeInterval, context: String
    ) throws {
        let sessionRow = app.buttons["terminal.row.\(sessionID)"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: timeout), "Terminal row \(sessionID) did not reappear during \(context)")
        XCTAssertTrue(revealTerminalRow(sessionRow, in: app, timeout: 8), "Terminal row \(sessionID) was not ready for interaction during \(context)")
        sessionRow.tap()

        let sessionDetail = app.descendants(matching: .any)["terminal.detail.\(sessionID)"]
        if !sessionDetail.waitForExistence(timeout: 8) {
            captureScreenshot(
                app, name: "terminal-detail-missing-\(context)",
                filePath: configuration.renderDumpPath.map { "\(($0 as NSString).deletingLastPathComponent)/terminal-detail-missing.png" })
            XCTFail("Terminal detail \(sessionID) did not appear during \(context)")
            return
        }
        if !waitForOwnerState(in: app, configuration: configuration, sessionID: sessionID, timeout: 4) {
            XCTAssertTrue(
                tapButton(in: app, identifier: "terminal.takeover", fallbackLabel: "Take Over", timeout: 8),
                "Timed out waiting for Take Over button during \(context)")
        }

        guard waitForOwnerState(in: app, configuration: configuration, sessionID: sessionID, timeout: 45) else {
            XCTFail("Timed out waiting for owner state after taking over session \(sessionID) during \(context)")
            return
        }
        XCTAssertTrue(
            waitForOwnerReadyState(in: app, configuration: configuration, sessionID: sessionID, timeout: 10),
            "Owner-ready state did not return promptly after taking over session \(sessionID) during \(context)")
        assertOwnerReadyStable(
            in: app, configuration: configuration, sessionID: sessionID, duration: 1,
            context: "after taking over session \(sessionID) during \(context)")
    }

    private func performScrollback(in app: XCUIApplication, configuration: UITestConfiguration) {
        guard configuration.scrollbackSwipeCount > 0 else { return }
        focusTerminalSurface(in: app)
        let startCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
        let endCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        for _ in 0..<configuration.scrollbackSwipeCount {
            startCoordinate.press(forDuration: 0.05, thenDragTo: endCoordinate)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
    }

    private func waitForStaticText(in app: XCUIApplication, identifier: String, fallbackLabel: String, timeout: TimeInterval) -> XCUIElement? {
        waitForElement(primary: app.staticTexts[identifier], fallback: app.staticTexts[fallbackLabel], timeout: timeout)
    }

    private func waitForElement(primary: XCUIElement, fallback: XCUIElement, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if primary.exists { return primary }
            if fallback.exists { return fallback }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func waitForRunningApp(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch app.state {
            case .runningForeground: return true
            default: RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        return false
    }

    private func waitForOwnerState(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ownerBadge = app.otherElements["terminal.ownerBadge"]
            if ownerBadge.exists { return ownerBadge }
            let ownerPreparing = app.descendants(matching: .any)["terminal.ownerPreparing"]
            if ownerPreparing.exists { return ownerPreparing }
            let ownerText = app.staticTexts["Owner"]
            if ownerText.exists { return ownerText }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func waitForOwnerState(in app: XCUIApplication, configuration: UITestConfiguration, sessionID: String? = nil, timeout: TimeInterval)
        -> Bool
    {
        let expectedSessionID = sessionID ?? configuration.sessionID
        if configuration.renderDumpPath != nil {
            return waitForRenderDump(configuration: configuration, timeout: timeout) { dump in
                dump.sessionID == expectedSessionID && dump.isOwner
                    && (dump.showsTerminalSurface || dump.renderMode.hasPrefix("owner") || dump.renderMode == "ghostty-mirror")
            } != nil
        }
        return waitForOwnerState(in: app, timeout: timeout) != nil
    }

    private func waitForOwnerReadyState(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isShowingOwnerReadyState(in: app) && !isShowingPreparingInput(in: app) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func waitForOwnerReadyState(in app: XCUIApplication, configuration: UITestConfiguration, sessionID: String? = nil, timeout: TimeInterval)
        -> Bool
    {
        let expectedSessionID = sessionID ?? configuration.sessionID
        if configuration.renderDumpPath != nil {
            return waitForRenderDump(configuration: configuration, timeout: timeout) { dump in
                isOwnerReady(dump, expectedSessionID: expectedSessionID)
            } != nil
        }
        return waitForOwnerReadyState(in: app, timeout: timeout)
    }

    private func assertOwnerReadyStable(in app: XCUIApplication, duration: TimeInterval, context: String) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            XCTAssertTrue(isShowingOwnerReadyState(in: app), "Owner-ready badge disappeared \(context)")
            XCTAssertFalse(isShowingPreparingInput(in: app), "Preparing input remained visible \(context)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func assertOwnerReadyStable(
        in app: XCUIApplication, configuration: UITestConfiguration, sessionID: String? = nil, duration: TimeInterval, context: String
    ) {
        if configuration.renderDumpPath == nil {
            assertOwnerReadyStable(in: app, duration: duration, context: context)
            return
        }
        let expectedSessionID = sessionID ?? configuration.sessionID
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            guard let dump = latestRenderDump(configuration: configuration) else {
                XCTFail("Missing render dump \(context)")
                return
            }
            XCTAssertTrue(isOwnerReady(dump, expectedSessionID: expectedSessionID), "Owner-ready render dump regressed \(context): \(dump)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func isShowingOwnerReadyState(in app: XCUIApplication) -> Bool {
        app.otherElements["terminal.ownerBadge"].exists || app.staticTexts["Owner"].exists
    }

    private func isShowingPreparingInput(in app: XCUIApplication) -> Bool {
        if app.descendants(matching: .any)["terminal.ownerPreparing"].exists { return true }
        return false
    }

    private func waitForRenderDump(configuration: UITestConfiguration, timeout: TimeInterval, predicate: (UITestRenderDump) -> Bool)
        -> UITestRenderDump?
    {
        guard configuration.renderDumpPath != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let dump = latestRenderDump(configuration: configuration), predicate(dump) { return dump }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if let dump = latestRenderDump(configuration: configuration), predicate(dump) { return dump }
        return nil
    }

    private func latestRenderDump(configuration: UITestConfiguration) -> UITestRenderDump? {
        guard let renderDumpPath = configuration.renderDumpPath else { return nil }
        let url = URL(fileURLWithPath: renderDumpPath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UITestRenderDump.self, from: data)
    }

    private func isOwnerReady(_ dump: UITestRenderDump, expectedSessionID: String) -> Bool {
        dump.sessionID == expectedSessionID && dump.isOwner && dump.showsTerminalSurface && dump.isInputSurfaceReady && !dump.isBusy
            && !dump.isPreparingInput
    }

    private func captureScreenshot(_ app: XCUIApplication, name: String, filePath: String?) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let filePath else { return }
        let url = URL(fileURLWithPath: filePath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: url, options: [.atomic])
        } catch { XCTFail("Failed to write screenshot \(name) to \(filePath): \(error)") }
    }

    private func waitForMarkerIfNeeded(_ path: String?, timeout: TimeInterval) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Timed out waiting for marker file at \(path)")
    }

    private func writeMarkerIfNeeded(_ path: String?) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "ready\n".write(to: url, atomically: true, encoding: .utf8)
        } catch { XCTFail("Failed writing marker file at \(path): \(error)") }
    }

    private func writeE2ECommandRequest(configuration: UITestConfiguration, key: String) throws {
        guard let eventLogPath = configuration.eventLogPath else {
            XCTFail("Missing E2E event log path for command request")
            return
        }
        let requestURL = URL(fileURLWithPath: "\(eventLogPath).command-request.json")
        try FileManager.default.createDirectory(at: requestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = ["id": "ui-key-\(Int(Date().timeIntervalSince1970 * 1000))", "key": key, "sendEnter": false]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: requestURL, options: [.atomic])
    }

    private func waitForE2EEvent(configuration: UITestConfiguration, kind: String, detailContains: String, timeout: TimeInterval) -> Bool {
        guard let eventLogPath = configuration.eventLogPath else { return false }
        let url = URL(fileURLWithPath: eventLogPath)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if e2eEventExists(at: url, kind: kind, detailContains: detailContains) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return e2eEventExists(at: url, kind: kind, detailContains: detailContains)
    }

    private func e2eEventExists(at url: URL, kind: String, detailContains: String) -> Bool {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8), let event = try? JSONDecoder().decode(UITestE2EEvent.self, from: lineData),
                event.kind == kind, event.detail?.contains(detailContains) == true
            else { continue }
            return true
        }
        return false
    }

    private func copyLatestRenderDump(configuration: UITestConfiguration, to path: String?) {
        guard let renderDumpPath = configuration.renderDumpPath, let path else { return }
        let sourceURL = URL(fileURLWithPath: renderDumpPath)
        let targetURL = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: targetURL, options: [.atomic])
        } catch { XCTFail("Failed copying render dump to \(path): \(error)") }
    }

}

private struct UITestConfiguration: Decodable {
    static let defaultConfigPath = "/tmp/spaces-mobile-ui-test-config.json"
    static let defaultBundleID = "dev.usespaces.spacesmobile"

    let sessionID: String
    let secondarySessionID: String?
    let deviceID: String?
    let deviceName: String?
    let host: String
    let port: Int
    let authToken: String
    let certificateFingerprint: String
    let installationID: String
    let renderDumpPath: String?
    let eventLogPath: String?
    let immediateScreenshotPath: String?
    let shortDelayScreenshotPath: String?
    let longDelayScreenshotPath: String?
    let proceedTakeOverPath: String?
    let firstCommandRequestPath: String?
    let firstCommandFocusedPath: String?
    let firstCommandCompletedPath: String?
    let firstCommandObservedPath: String?
    let secondCommandRequestPath: String?
    let secondCommandFocusedPath: String?
    let secondCommandCompletedPath: String?
    let secondCommandObservedPath: String?
    let proceedFinishPath: String?
    let firstCommandText: String
    let secondCommandText: String?
    let manualRetakeoverAttempts: Int
    let manualRetakeoverObservedPrefix: String?
    let manualRetakeoverContinuePrefix: String?
    let postFirstCommandScreenshotPath: String?
    let postSecondCommandScreenshotPath: String?
    let interruptedRenderDumpPath: String?
    let postInterruptScreenshotPath: String?
    let finalMacRetakeoverRequestPath: String?
    let finalMacRetakeoverObservedPath: String?
    let postFinalMacRetakeoverScreenshotPath: String?
    let finalScreenshotPath: String?
    let terminalLinkText: String
    let expectedLinkPreviewTitle: String
    let linkPreviewScreenshotPath: String?
    let expectedInterruptedText: String
    let expectedSecondaryText: String
    let scrollbackSwipeCount: Int
    let minimumVisibleTerminalInkBands: Int
    let maximumTerminalTopBlankRatio: Double
    let attachToExistingApp: Bool
    let bundleID: String
    let targetWorkspaceID: String
    let removalScrollSeconds: Double
    let terminalRowRemovalTimeoutSeconds: Double

    var deviceSeedJSON: String? {
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...65_535).contains(port),
            !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let payload: [String: Any] = [
            "activeDeviceID": deviceID ?? "",
            "devices": [
                [
                    "id": deviceID ?? "", "name": deviceName ?? "This Mac", "host": host, "port": port, "authToken": authToken,
                    "certificateFingerprint": certificateFingerprint,
                ]
            ],
        ]
        guard JSONSerialization.isValidJSONObject(payload), let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case secondarySessionID
        case deviceID
        case deviceName
        case host
        case port
        case authToken
        case certificateFingerprint
        case installationID
        case renderDumpPath
        case eventLogPath
        case immediateScreenshotPath
        case shortDelayScreenshotPath
        case longDelayScreenshotPath
        case proceedTakeOverPath
        case firstCommandRequestPath
        case firstCommandFocusedPath
        case firstCommandCompletedPath
        case firstCommandObservedPath
        case secondCommandRequestPath
        case secondCommandFocusedPath
        case secondCommandCompletedPath
        case secondCommandObservedPath
        case proceedFinishPath
        case firstCommandText
        case secondCommandText
        case manualRetakeoverAttempts
        case manualRetakeoverObservedPrefix
        case manualRetakeoverContinuePrefix
        case postFirstCommandScreenshotPath
        case postSecondCommandScreenshotPath
        case interruptedRenderDumpPath
        case postInterruptScreenshotPath
        case finalMacRetakeoverRequestPath
        case finalMacRetakeoverObservedPath
        case postFinalMacRetakeoverScreenshotPath
        case finalScreenshotPath
        case terminalLinkText
        case expectedLinkPreviewTitle
        case linkPreviewScreenshotPath
        case expectedInterruptedText
        case expectedSecondaryText
        case scrollbackSwipeCount
        case minimumVisibleTerminalInkBands
        case maximumTerminalTopBlankRatio
        case attachToExistingApp
        case bundleID
        case targetWorkspaceID
        case removalScrollSeconds
        case terminalRowRemovalTimeoutSeconds
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachToExistingApp = try container.decodeIfPresent(Bool.self, forKey: .attachToExistingApp) ?? false
        sessionID = try container.decode(String.self, forKey: .sessionID)
        secondarySessionID = try container.decodeIfPresent(String.self, forKey: .secondarySessionID)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        authToken = try container.decode(String.self, forKey: .authToken)
        if attachToExistingApp {
            certificateFingerprint = try container.decodeIfPresent(String.self, forKey: .certificateFingerprint) ?? ""
        } else {
            certificateFingerprint = try container.decode(String.self, forKey: .certificateFingerprint)
        }
        installationID = try container.decode(String.self, forKey: .installationID)
        renderDumpPath = try container.decodeIfPresent(String.self, forKey: .renderDumpPath)
        eventLogPath = try container.decodeIfPresent(String.self, forKey: .eventLogPath)
        immediateScreenshotPath = try container.decodeIfPresent(String.self, forKey: .immediateScreenshotPath)
        shortDelayScreenshotPath = try container.decodeIfPresent(String.self, forKey: .shortDelayScreenshotPath)
        longDelayScreenshotPath = try container.decodeIfPresent(String.self, forKey: .longDelayScreenshotPath)
        proceedTakeOverPath = try container.decodeIfPresent(String.self, forKey: .proceedTakeOverPath)
        firstCommandRequestPath = try container.decodeIfPresent(String.self, forKey: .firstCommandRequestPath)
        firstCommandFocusedPath = try container.decodeIfPresent(String.self, forKey: .firstCommandFocusedPath)
        firstCommandCompletedPath = try container.decodeIfPresent(String.self, forKey: .firstCommandCompletedPath)
        firstCommandObservedPath = try container.decodeIfPresent(String.self, forKey: .firstCommandObservedPath)
        secondCommandRequestPath = try container.decodeIfPresent(String.self, forKey: .secondCommandRequestPath)
        secondCommandFocusedPath = try container.decodeIfPresent(String.self, forKey: .secondCommandFocusedPath)
        secondCommandCompletedPath = try container.decodeIfPresent(String.self, forKey: .secondCommandCompletedPath)
        secondCommandObservedPath = try container.decodeIfPresent(String.self, forKey: .secondCommandObservedPath)
        proceedFinishPath = try container.decodeIfPresent(String.self, forKey: .proceedFinishPath)
        firstCommandText = try container.decodeIfPresent(String.self, forKey: .firstCommandText) ?? ""
        secondCommandText = try container.decodeIfPresent(String.self, forKey: .secondCommandText)
        manualRetakeoverAttempts = try container.decodeIfPresent(Int.self, forKey: .manualRetakeoverAttempts) ?? 0
        manualRetakeoverObservedPrefix = try container.decodeIfPresent(String.self, forKey: .manualRetakeoverObservedPrefix)
        manualRetakeoverContinuePrefix = try container.decodeIfPresent(String.self, forKey: .manualRetakeoverContinuePrefix)
        postFirstCommandScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postFirstCommandScreenshotPath)
        postSecondCommandScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postSecondCommandScreenshotPath)
        interruptedRenderDumpPath = try container.decodeIfPresent(String.self, forKey: .interruptedRenderDumpPath)
        postInterruptScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postInterruptScreenshotPath)
        finalMacRetakeoverRequestPath = try container.decodeIfPresent(String.self, forKey: .finalMacRetakeoverRequestPath)
        finalMacRetakeoverObservedPath = try container.decodeIfPresent(String.self, forKey: .finalMacRetakeoverObservedPath)
        postFinalMacRetakeoverScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postFinalMacRetakeoverScreenshotPath)
        finalScreenshotPath = try container.decodeIfPresent(String.self, forKey: .finalScreenshotPath)
        terminalLinkText = try container.decodeIfPresent(String.self, forKey: .terminalLinkText) ?? ""
        expectedLinkPreviewTitle = try container.decodeIfPresent(String.self, forKey: .expectedLinkPreviewTitle) ?? terminalLinkText
        linkPreviewScreenshotPath = try container.decodeIfPresent(String.self, forKey: .linkPreviewScreenshotPath)
        expectedInterruptedText = try container.decodeIfPresent(String.self, forKey: .expectedInterruptedText) ?? ""
        expectedSecondaryText = try container.decodeIfPresent(String.self, forKey: .expectedSecondaryText) ?? ""
        scrollbackSwipeCount = try container.decodeIfPresent(Int.self, forKey: .scrollbackSwipeCount) ?? 0
        minimumVisibleTerminalInkBands = try container.decodeIfPresent(Int.self, forKey: .minimumVisibleTerminalInkBands) ?? 0
        maximumTerminalTopBlankRatio = try container.decodeIfPresent(Double.self, forKey: .maximumTerminalTopBlankRatio) ?? 0
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ?? Self.defaultBundleID
        targetWorkspaceID = try container.decodeIfPresent(String.self, forKey: .targetWorkspaceID) ?? ""
        removalScrollSeconds = try container.decodeIfPresent(Double.self, forKey: .removalScrollSeconds) ?? 12
        terminalRowRemovalTimeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .terminalRowRemovalTimeoutSeconds) ?? 90
    }

    func manualRetakeoverObservedPath(for attemptIndex: Int) -> String? {
        guard let manualRetakeoverObservedPrefix else { return nil }
        return "\(manualRetakeoverObservedPrefix)-\(attemptIndex + 1)"
    }

    func manualRetakeoverContinuePath(for attemptIndex: Int) -> String? {
        guard let manualRetakeoverContinuePrefix else { return nil }
        return "\(manualRetakeoverContinuePrefix)-\(attemptIndex + 1)"
    }

    static func load(environment: [String: String]) throws -> Self {
        let configPath = environment["SPACES_MOBILE_UI_TEST_CONFIG_PATH"] ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw UITestConfigurationError.missingConfigFile(configPath) }
        do { return try JSONDecoder().decode(Self.self, from: data) } catch {
            throw UITestConfigurationError.invalidConfigFile(configPath, error.localizedDescription)
        }
    }
}

private struct UITestRenderDump: Decodable, CustomStringConvertible {
    let sessionID: String
    let renderMode: String
    let isOwner: Bool
    let showsTerminalSurface: Bool
    let isBusy: Bool
    let isPreparingInput: Bool
    let isInputSurfaceReady: Bool
    let viewportColumns: Int?
    let viewportRows: Int?
    let snapshotText: String?
    let errorMessage: String?
    let isPreparingLinkPreview: Bool
    let linkPreviewTitle: String?
    let linkPreviewArtifactKind: String?
    let linkPreviewErrorMessage: String?
    let visibleText: String
    let renderedText: String
    let renderStateKey: String

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case renderMode
        case isOwner
        case showsTerminalSurface
        case isBusy
        case isPreparingInput
        case isInputSurfaceReady
        case viewportColumns
        case viewportRows
        case snapshotText
        case errorMessage
        case isPreparingLinkPreview
        case linkPreviewTitle
        case linkPreviewArtifactKind
        case linkPreviewErrorMessage
        case visibleText
        case renderedText
        case renderStateKey
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        renderMode = try container.decode(String.self, forKey: .renderMode)
        isOwner = try container.decode(Bool.self, forKey: .isOwner)
        showsTerminalSurface = try container.decode(Bool.self, forKey: .showsTerminalSurface)
        isBusy = try container.decode(Bool.self, forKey: .isBusy)
        isPreparingInput = try container.decode(Bool.self, forKey: .isPreparingInput)
        isInputSurfaceReady = try container.decode(Bool.self, forKey: .isInputSurfaceReady)
        viewportColumns = try container.decodeIfPresent(Int.self, forKey: .viewportColumns)
        viewportRows = try container.decodeIfPresent(Int.self, forKey: .viewportRows)
        snapshotText = try container.decodeIfPresent(String.self, forKey: .snapshotText)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        isPreparingLinkPreview = try container.decodeIfPresent(Bool.self, forKey: .isPreparingLinkPreview) ?? false
        linkPreviewTitle = try container.decodeIfPresent(String.self, forKey: .linkPreviewTitle)
        linkPreviewArtifactKind = try container.decodeIfPresent(String.self, forKey: .linkPreviewArtifactKind)
        linkPreviewErrorMessage = try container.decodeIfPresent(String.self, forKey: .linkPreviewErrorMessage)
        visibleText = try container.decode(String.self, forKey: .visibleText)
        renderedText = try container.decode(String.self, forKey: .renderedText)
        renderStateKey = try container.decode(String.self, forKey: .renderStateKey)
    }

    var combinedText: String { [renderedText, snapshotText ?? "", visibleText].joined(separator: "\n") }

    var hasError: Bool {
        guard let errorMessage else { return false }
        return !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasLinkPreviewError: Bool {
        guard let linkPreviewErrorMessage else { return false }
        return !linkPreviewErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasLinkPreview(title expectedTitle: String, artifactKind expectedArtifactKind: String) -> Bool {
        guard !isPreparingLinkPreview else { return false }
        guard linkPreviewArtifactKind == expectedArtifactKind else { return false }
        guard let linkPreviewTitle else { return false }
        return expectedTitle.isEmpty || linkPreviewTitle == expectedTitle
    }

    var description: String {
        [
            "sessionID=\(sessionID)", "renderMode=\(renderMode)", "isOwner=\(isOwner)", "showsTerminalSurface=\(showsTerminalSurface)",
            "isBusy=\(isBusy)", "isPreparingInput=\(isPreparingInput)", "isInputSurfaceReady=\(isInputSurfaceReady)",
            "viewport=\(viewportColumns.map(String.init) ?? "?")x\(viewportRows.map(String.init) ?? "?")", "errorMessage=\(errorMessage ?? "")",
            "isPreparingLinkPreview=\(isPreparingLinkPreview)", "linkPreviewTitle=\(linkPreviewTitle ?? "")",
            "linkPreviewArtifactKind=\(linkPreviewArtifactKind ?? "")", "linkPreviewErrorMessage=\(linkPreviewErrorMessage ?? "")",
            "visibleText=\(visibleText)", "snapshotTextLength=\(snapshotText?.count ?? 0)", "renderedTextLength=\(renderedText.count)",
            "renderStateKey=\(renderStateKey)",
        ].joined(separator: " ")
    }
}

private struct UITestE2EEvent: Decodable {
    let kind: String?
    let detail: String?
}

private struct TerminalSurfaceInkMetrics: CustomStringConvertible {
    let width: Int
    let height: Int
    let brightPixels: Int
    let inkRows: Int
    let inkBands: Int
    let firstInkRow: Int?

    var description: String {
        "width=\(width) height=\(height) brightPixels=\(brightPixels) inkRows=\(inkRows) "
            + "inkBands=\(inkBands) firstInkRow=\(String(describing: firstInkRow))"
    }
}

private enum UITestConfigurationError: LocalizedError {
    case missingConfigFile(String)
    case invalidConfigFile(String, String)

    var errorDescription: String? {
        switch self {
        case .missingConfigFile(let path): return "Missing UI test config file at \(path)"
        case .invalidConfigFile(let path, let message): return "Invalid UI test config file at \(path): \(message)"
        }
    }
}
