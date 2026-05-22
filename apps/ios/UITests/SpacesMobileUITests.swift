import Foundation
import XCTest

final class SpacesMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTerminalTakeOverFromList() throws {
        try runTerminalTakeOverScenario()
    }

    func testTerminalTakeOverAfterMacRetakeover() throws {
        try runTerminalTakeOverScenario()
    }

    func testTerminalTakeOverAfterTwoMacRetakeovers() throws {
        try runTerminalTakeOverScenario()
    }

    func testTerminalTakeOverRoundTripWithCommands() throws {
        try runTerminalTakeOverScenario()
    }

    func testTerminalTakeOverAcrossTwoSessionsFromList() throws {
        try runTerminalTakeOverScenario()
    }

    func testTerminalTakeOverReopenSameSessionFromList() throws {
        try runTerminalTakeOverScenario()
    }

    private func runTerminalTakeOverScenario() throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = if configuration.attachToExistingApp {
            XCUIApplication(bundleIdentifier: configuration.bundleID)
        } else {
            XCUIApplication()
        }
        if configuration.attachToExistingApp {
            app.activate()
            XCTAssertTrue(waitForRunningApp(app, timeout: 20), "Timed out waiting for attached app \(configuration.bundleID) to become active")
        } else {
            app.launchEnvironment["SPACES_MOBILE_TEST_HOST"] = configuration.host
            app.launchEnvironment["SPACES_MOBILE_TEST_PORT"] = String(configuration.port)
            app.launchEnvironment["SPACES_MOBILE_TEST_AUTH_TOKEN"] = configuration.authToken
            app.launchEnvironment["SPACES_MOBILE_TEST_INSTALLATION_ID"] = configuration.installationID
            app.launchEnvironment["SPACES_MOBILE_E2E_TARGET_SESSION_ID"] = configuration.sessionID
            if let renderDumpPath = configuration.renderDumpPath {
                app.launchEnvironment["SPACES_MOBILE_E2E_RENDER_DUMP_PATH"] = renderDumpPath
            }
            if let eventLogPath = configuration.eventLogPath {
                app.launchEnvironment["SPACES_MOBILE_E2E_EVENT_LOG_PATH"] = eventLogPath
            }
            app.launch()
        }
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let sessionRow = app.buttons["terminal.row.\(configuration.sessionID)"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 20), "Timed out waiting for session row \(configuration.sessionID)")
        sessionRow.tap()
        waitForMarkerIfNeeded(configuration.proceedTakeOverPath, timeout: 20)

        guard waitForOwnerState(in: app, timeout: 20) != nil else {
            XCTFail("Timed out waiting for owner state")
            return
        }

        captureScreenshot(app, name: "post-takeover-immediate", filePath: configuration.immediateScreenshotPath)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        captureScreenshot(app, name: "post-takeover-plus-2s", filePath: configuration.shortDelayScreenshotPath)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        captureScreenshot(app, name: "post-takeover-plus-6s", filePath: configuration.longDelayScreenshotPath)
        if let secondarySessionID = configuration.secondarySessionID {
            try takeOverSessionsAcrossListCycles(
                in: app,
                configuration: configuration,
                sessionIDs: [secondarySessionID, configuration.sessionID, secondarySessionID]
            )
            return
        }
        if configuration.scrollbackSwipeCount > 0 {
            performScrollback(in: app, configuration: configuration)
            captureScreenshot(app, name: "post-scrollback", filePath: configuration.finalScreenshotPath)
        }

        if let firstCommandRequestPath = configuration.firstCommandRequestPath {
            waitForMarkerIfNeeded(firstCommandRequestPath, timeout: 20)
            focusTerminalSurface(in: app)
            writeMarkerIfNeeded(configuration.firstCommandFocusedPath)
            waitForMarkerIfNeeded(configuration.firstCommandCompletedPath, timeout: 20)
            XCTAssertTrue(waitForOwnerReadyState(in: app, timeout: 1), "Owner-ready badge did not return promptly after first iOS command")
            assertOwnerReadyStable(in: app, duration: 1, context: "after first iOS command")
            captureScreenshot(app, name: "post-ios-command-immediate", filePath: configuration.postFirstCommandScreenshotPath)
            writeMarkerIfNeeded(configuration.firstCommandObservedPath)
            if let secondCommandRequestPath = configuration.secondCommandRequestPath {
                waitForMarkerIfNeeded(secondCommandRequestPath, timeout: 20)
                focusTerminalSurface(in: app)
                writeMarkerIfNeeded(configuration.secondCommandFocusedPath)
                waitForMarkerIfNeeded(configuration.secondCommandCompletedPath, timeout: 20)
                XCTAssertTrue(waitForOwnerReadyState(in: app, timeout: 1), "Owner-ready badge did not return promptly after second iOS command")
                assertOwnerReadyStable(in: app, duration: 1, context: "after second iOS command")
                captureScreenshot(app, name: "post-ios-second-command", filePath: configuration.postSecondCommandScreenshotPath)
                writeMarkerIfNeeded(configuration.secondCommandObservedPath)
            }
        }

        if let proceedFinishPath = configuration.proceedFinishPath {
            waitForMarkerIfNeeded(proceedFinishPath, timeout: 30)
            for attemptIndex in 0..<configuration.manualRetakeoverAttempts {
                guard let takeOverButton = waitForButton(
                    in: app,
                    identifier: "terminal.takeover",
                    fallbackLabel: "Take Over",
                    timeout: 20
                ) else {
                    XCTFail("Timed out waiting for Take Over button after Mac retakeover")
                    return
                }
                takeOverButton.tap()
                guard waitForOwnerState(in: app, timeout: 20) != nil else {
                    XCTFail("Timed out waiting for owner state after iPad retakeover attempt \(attemptIndex + 1)")
                    return
                }
                XCTAssertTrue(
                    waitForOwnerReadyState(in: app, timeout: 5),
                    "Owner-ready badge did not return promptly after iPad retakeover attempt \(attemptIndex + 1)"
                )
                assertOwnerReadyStable(in: app, duration: 1, context: "after iPad retakeover attempt \(attemptIndex + 1)")
                writeMarkerIfNeeded(configuration.manualRetakeoverObservedPath(for: attemptIndex))
            }
            if let finalMacRetakeoverRequestPath = configuration.finalMacRetakeoverRequestPath {
                waitForMarkerIfNeeded(finalMacRetakeoverRequestPath, timeout: 30)
                guard waitForButton(
                    in: app,
                    identifier: "terminal.takeover",
                    fallbackLabel: "Take Over",
                    timeout: 20
                ) != nil else {
                    XCTFail("Timed out waiting for Take Over button after the final Mac retakeover")
                    return
                }
                captureScreenshot(
                    app,
                    name: "post-final-mac-retakeover",
                    filePath: configuration.postFinalMacRetakeoverScreenshotPath
                )
                writeMarkerIfNeeded(configuration.finalMacRetakeoverObservedPath)
            }
            captureScreenshot(app, name: "post-mac-retakeover", filePath: configuration.finalScreenshotPath)
        }
    }

    private func waitForButton(in app: XCUIApplication, identifier: String, fallbackLabel: String, timeout: TimeInterval) -> XCUIElement? {
        waitForElement(primary: app.buttons[identifier], fallback: app.buttons[fallbackLabel], timeout: timeout)
    }

    private func focusTerminalSurface(in app: XCUIApplication) {
        let terminalSurface = app.otherElements["terminal.surface"]
        if terminalSurface.waitForExistence(timeout: 2) {
            terminalSurface.tap()
        }
    }

    private func takeOverSessionsAcrossListCycles(
        in app: XCUIApplication,
        configuration: UITestConfiguration,
        sessionIDs: [String]
    ) throws {
        for (index, sessionID) in sessionIDs.enumerated() {
            try returnToTerminalList(in: app)
            try takeOverSessionFromList(
                in: app,
                sessionID: sessionID,
                timeout: 20,
                context: "list cycle \(index + 1)"
            )
        }
        captureScreenshot(app, name: "post-second-session-takeover", filePath: configuration.finalScreenshotPath)
    }

    private func returnToTerminalList(in app: XCUIApplication) throws {
        let backButton = app.buttons["terminal.back"]
        if backButton.waitForExistence(timeout: 2) {
            backButton.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.06)).tap()
        }
        XCTAssertTrue(waitForRunningApp(app, timeout: 5), "App stopped running after returning to the terminal list")
    }

    private func takeOverSessionFromList(
        in app: XCUIApplication,
        sessionID: String,
        timeout: TimeInterval,
        context: String
    ) throws {
        let sessionRow = app.buttons["terminal.row.\(sessionID)"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: timeout), "Terminal row \(sessionID) did not reappear during \(context)")
        sessionRow.tap()

        guard waitForOwnerState(in: app, timeout: 20) != nil else {
            XCTFail("Timed out waiting for owner state after taking over session \(sessionID) during \(context)")
            return
        }
        XCTAssertTrue(waitForOwnerReadyState(in: app, timeout: 5), "Owner-ready badge did not return promptly after taking over session \(sessionID) during \(context)")
        assertOwnerReadyStable(in: app, duration: 1, context: "after taking over session \(sessionID) during \(context)")
    }

    private func performScrollback(in app: XCUIApplication, configuration: UITestConfiguration) {
        guard configuration.scrollbackSwipeCount > 0 else { return }
        focusTerminalSurface(in: app)
        let startCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        let endCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36))
        for _ in 0..<configuration.scrollbackSwipeCount {
            startCoordinate.press(forDuration: 0.05, thenDragTo: endCoordinate)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        }
    }

    private func waitForStaticText(
        in app: XCUIApplication,
        identifier: String,
        fallbackLabel: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        waitForElement(primary: app.staticTexts[identifier], fallback: app.staticTexts[fallbackLabel], timeout: timeout)
    }

    private func waitForElement(primary: XCUIElement, fallback: XCUIElement, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if primary.exists {
                return primary
            }
            if fallback.exists {
                return fallback
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func waitForRunningApp(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch app.state {
            case .runningForeground:
                return true
            default:
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        return false
    }

    private func waitForOwnerState(in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ownerBadge = app.otherElements["terminal.ownerBadge"]
            if ownerBadge.exists {
                return ownerBadge
            }
            let ownerPreparing = app.otherElements["terminal.ownerPreparing"]
            if ownerPreparing.exists {
                return ownerPreparing
            }
            let ownerText = app.staticTexts["Owner"]
            if ownerText.exists {
                return ownerText
            }
            let preparingText = app.staticTexts["Preparing input…"]
            if preparingText.exists {
                return preparingText
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    private func waitForOwnerReadyState(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isShowingOwnerReadyState(in: app) && !isShowingPreparingInput(in: app) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func assertOwnerReadyStable(in app: XCUIApplication, duration: TimeInterval, context: String) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            XCTAssertTrue(isShowingOwnerReadyState(in: app), "Owner-ready badge disappeared \(context)")
            XCTAssertFalse(isShowingPreparingInput(in: app), "Preparing input remained visible \(context)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func isShowingOwnerReadyState(in app: XCUIApplication) -> Bool {
        app.otherElements["terminal.ownerBadge"].exists || app.staticTexts["Owner"].exists
    }

    private func isShowingPreparingInput(in app: XCUIApplication) -> Bool {
        if app.otherElements["terminal.ownerPreparing"].exists {
            return true
        }
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Preparing input")).count > 0
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
        } catch {
            XCTFail("Failed to write screenshot \(name) to \(filePath): \(error)")
        }
    }

    private func waitForMarkerIfNeeded(_ path: String?, timeout: TimeInterval) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return
            }
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
        } catch {
            XCTFail("Failed writing marker file at \(path): \(error)")
        }
    }

}

private struct UITestConfiguration: Decodable {
    static let defaultConfigPath = "/tmp/spaces-mobile-ui-test-config.json"
    static let defaultBundleID = "com.yogeshdhande.spacesmobile"

    let sessionID: String
    let secondarySessionID: String?
    let host: String
    let port: Int
    let authToken: String
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
    let postFirstCommandScreenshotPath: String?
    let postSecondCommandScreenshotPath: String?
    let finalMacRetakeoverRequestPath: String?
    let finalMacRetakeoverObservedPath: String?
    let postFinalMacRetakeoverScreenshotPath: String?
    let finalScreenshotPath: String?
    let scrollbackSwipeCount: Int
    let attachToExistingApp: Bool
    let bundleID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case secondarySessionID
        case host
        case port
        case authToken
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
        case postFirstCommandScreenshotPath
        case postSecondCommandScreenshotPath
        case finalMacRetakeoverRequestPath
        case finalMacRetakeoverObservedPath
        case postFinalMacRetakeoverScreenshotPath
        case finalScreenshotPath
        case scrollbackSwipeCount
        case attachToExistingApp
        case bundleID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        secondarySessionID = try container.decodeIfPresent(String.self, forKey: .secondarySessionID)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        authToken = try container.decode(String.self, forKey: .authToken)
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
        postFirstCommandScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postFirstCommandScreenshotPath)
        postSecondCommandScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postSecondCommandScreenshotPath)
        finalMacRetakeoverRequestPath = try container.decodeIfPresent(String.self, forKey: .finalMacRetakeoverRequestPath)
        finalMacRetakeoverObservedPath = try container.decodeIfPresent(String.self, forKey: .finalMacRetakeoverObservedPath)
        postFinalMacRetakeoverScreenshotPath = try container.decodeIfPresent(String.self, forKey: .postFinalMacRetakeoverScreenshotPath)
        finalScreenshotPath = try container.decodeIfPresent(String.self, forKey: .finalScreenshotPath)
        scrollbackSwipeCount = try container.decodeIfPresent(Int.self, forKey: .scrollbackSwipeCount) ?? 0
        attachToExistingApp = try container.decodeIfPresent(Bool.self, forKey: .attachToExistingApp) ?? false
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID) ?? Self.defaultBundleID
    }

    func manualRetakeoverObservedPath(for attemptIndex: Int) -> String? {
        guard let manualRetakeoverObservedPrefix else { return nil }
        return "\(manualRetakeoverObservedPrefix)-\(attemptIndex + 1)"
    }

    static func load(environment: [String: String]) throws -> Self {
        let configPath = environment["SPACES_MOBILE_UI_TEST_CONFIG_PATH"] ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw UITestConfigurationError.missingConfigFile(configPath)
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw UITestConfigurationError.invalidConfigFile(configPath, error.localizedDescription)
        }
    }
}

private enum UITestConfigurationError: LocalizedError {
    case missingConfigFile(String)
    case invalidConfigFile(String, String)

    var errorDescription: String? {
        switch self {
        case .missingConfigFile(let path):
            return "Missing UI test config file at \(path)"
        case .invalidConfigFile(let path, let message):
            return "Invalid UI test config file at \(path): \(message)"
        }
    }
}
