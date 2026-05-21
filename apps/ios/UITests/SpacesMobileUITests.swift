import Foundation
import XCTest

final class SpacesMobileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTerminalTakeOverFromList() throws {
        let configuration = try UITestConfiguration.load(environment: ProcessInfo.processInfo.environment)
        let app = XCUIApplication()
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
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let sessionRow = app.buttons["terminal.row.\(configuration.sessionID)"]
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 20), "Timed out waiting for session row \(configuration.sessionID)")
        sessionRow.tap()
        waitForMarkerIfNeeded(configuration.proceedTakeOverPath, timeout: 20)

        guard let takeOverButton = waitForButton(in: app, identifier: "terminal.takeover", fallbackLabel: "Take Over", timeout: 10) else {
            XCTFail("Timed out waiting for takeover button")
            return
        }
        takeOverButton.tap()

        guard let ownerState = waitForOwnerState(in: app, timeout: 20) else {
            XCTFail("Timed out waiting for owner state")
            return
        }
        XCTAssertTrue(ownerState.exists)

        captureScreenshot(app, name: "post-takeover-immediate", filePath: configuration.immediateScreenshotPath)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        captureScreenshot(app, name: "post-takeover-plus-2s", filePath: configuration.shortDelayScreenshotPath)
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        captureScreenshot(app, name: "post-takeover-plus-6s", filePath: configuration.longDelayScreenshotPath)

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
            captureScreenshot(app, name: "post-mac-retakeover", filePath: configuration.finalScreenshotPath)
        }
    }

    private func waitForButton(in app: XCUIApplication, identifier: String, fallbackLabel: String, timeout: TimeInterval) -> XCUIElement? {
        waitForElement(primary: app.buttons[identifier], fallback: app.buttons[fallbackLabel], timeout: timeout)
    }

    private func focusTerminalSurface(in app: XCUIApplication) {
        let terminalCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        terminalCoordinate.tap()
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

    let sessionID: String
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
    let postFirstCommandScreenshotPath: String?
    let postSecondCommandScreenshotPath: String?
    let finalScreenshotPath: String?

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
