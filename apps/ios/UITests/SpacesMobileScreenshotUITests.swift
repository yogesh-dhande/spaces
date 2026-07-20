import Foundation
import XCTest

/// Stages the app on a chosen screen and holds it there so a host process can capture App Store
/// screenshots with `xcrun simctl io <udid> screenshot` while this test idles. It performs no
/// screenshot capture itself — navigation only. See docs/dev.md for the exact invocation.
///
/// The paywall screenshot (`SPACES_MOBILE_SCREENSHOT_PAYWALL=1`) relies on the scheme's Test-action
/// StoreKit configuration to supply the local product catalog, so the paywall renders its real price
/// line; nothing StoreKit-specific is needed here.
final class SpacesMobileScreenshotUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// Reads `SPACES_MOBILE_SCREENSHOT_*` env vars as plain (non-`TEST_RUNNER_`-prefixed) names —
    /// the same form `SPACES_MOBILE_UI_TEST_CONFIG_PATH` already relies on for `xcodebuild
    /// test-without-building` against an iOS Simulator destination — launches the app paired
    /// against the demo daemon, navigates to the requested tab (and optionally a Spaces row), then
    /// holds the app foreground and idle so the host can screenshot it.
    func testScreenshotStaging() throws {
        let environment = ProcessInfo.processInfo.environment
        let showsPaywall = environment["SPACES_MOBILE_SCREENSHOT_PAYWALL"] == "1"
        // Demo Mode staging needs no daemon and no paired-device config: the bundled sample recording
        // supplies every tab's content, so the App Store screenshot set can be produced from a plain
        // simulator. The daemon-backed lane below is untouched.
        let usesDemoMode = environment["SPACES_MOBILE_SCREENSHOT_DEMO"] == "1"

        let app = XCUIApplication()
        if usesDemoMode {
            app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1"
            applyCleanSlateLaunchArguments(to: app)
        } else {
            let configuration = try ScreenshotUITestConfiguration.load(environment: environment)
            applyLaunchEnvironment(to: app, configuration: configuration, includePaywallBypass: !showsPaywall)
        }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        if usesDemoMode { XCTAssertTrue(enableDemoMode(in: app, timeout: 20), "Timed out enabling Demo Mode for screenshot staging") }

        // The paywall gates the whole app shell, so there is no tab bar to navigate while it is
        // showing: the screenshot is just the paywall itself, held idle below.
        if !showsPaywall {
            guard let rawTab = environment["SPACES_MOBILE_SCREENSHOT_TAB"], let tab = ScreenshotTab(rawValue: rawTab) else {
                XCTFail("Missing or invalid SPACES_MOBILE_SCREENSHOT_TAB (expected alerts, spaces, agents, or settings)")
                return
            }
            XCTAssertTrue(selectTab(tab, in: app, timeout: 20), "Timed out selecting the \(tab.rawValue) tab")

            if tab == .spaces, let rowTitle = environment["SPACES_MOBILE_SCREENSHOT_OPEN_ROW"], !rowTitle.isEmpty {
                XCTAssertTrue(openRow(titled: rowTitle, in: app, timeout: 20), "Timed out opening a row containing \"\(rowTitle)\"")
            }
        }

        let holdSeconds = environment["SPACES_MOBILE_SCREENSHOT_HOLD_SECONDS"].flatMap(Double.init) ?? 45
        RunLoop.current.run(until: Date().addingTimeInterval(max(holdSeconds, 0)))
    }

    /// Shadows the persistence keys through the argument domain so a demo-mode screenshot launch
    /// starts not-paired and Demo-off regardless of prior simulator state, matching
    /// `SpacesMobileDemoModeUITests`. Non-Data strings make `UserDefaults.data(forKey:)` return nil.
    private func applyCleanSlateLaunchArguments(to app: XCUIApplication) {
        app.launchArguments += [
            "-spaces.mobile.demo-mode-enabled", "0", "-spaces.mobile.paired-devices", "-", "-spaces.mobile.connection-settings", "-",
        ]
    }

    /// Taps Try Demo Mode from the unpaired Spaces empty state and waits for the Demo Mode banner.
    private func enableDemoMode(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let tryDemo = app.buttons["spaces.tryDemoMode"]
        guard tryDemo.waitForExistence(timeout: timeout) else { return false }
        tryDemo.tap()
        // Match the banner across the whole hierarchy: SwiftUI may surface the identified container as
        // an `other` element or fold it, so a type-specific query is unreliable.
        return app.descendants(matching: .any)["demo.banner"].waitForExistence(timeout: timeout)
    }

    private func applyLaunchEnvironment(to app: XCUIApplication, configuration: ScreenshotUITestConfiguration, includePaywallBypass: Bool) {
        // DEBUG-only paywall bypass, mirrors SpacesMobileUITests. Omitted only when the caller wants
        // the real paywall to render, e.g. the App Store Connect subscription-review screenshot.
        if includePaywallBypass { app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1" }
        app.launchEnvironment["SPACES_MOBILE_TEST_HOST"] = configuration.host
        app.launchEnvironment["SPACES_MOBILE_TEST_PORT"] = String(configuration.port)
        app.launchEnvironment["SPACES_MOBILE_TEST_AUTH_TOKEN"] = configuration.authToken
        app.launchEnvironment["SPACES_MOBILE_TEST_CERTIFICATE_FINGERPRINT"] = configuration.certificateFingerprint
        app.launchEnvironment["SPACES_MOBILE_TEST_INSTALLATION_ID"] = configuration.installationID
        if let deviceSeedJSON = configuration.deviceSeedJSON { app.launchEnvironment["SPACES_MOBILE_TEST_DEVICE_SEED_JSON"] = deviceSeedJSON }
    }

    private func selectTab(_ tab: ScreenshotTab, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", tab.label)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // iPhone renders a bottom tab bar whose buttons are hittable. iPad renders the same tabs
            // as a top bar whose buttons are nested and report `isHittable == false`, so fall back to
            // tapping the button's center coordinate, which works regardless of hittability.
            for scope in [app.tabBars.buttons, app.buttons] {
                let button = scope.matching(predicate).firstMatch
                guard button.exists else { continue }
                if button.isHittable { button.tap() } else { button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    /// Taps the first button whose accessibility label contains `titleSubstring`, scrolling the
    /// Spaces list into view first if needed. Matches on label text rather than a row identifier
    /// since the host supplies a human-readable title (or substring), not a session ID.
    private func openRow(titled titleSubstring: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", titleSubstring)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let row = app.buttons.matching(predicate).firstMatch
            if row.exists, row.isHittable {
                row.tap()
                return true
            }
            if row.exists { app.swipeUp() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }
}

/// The four bottom tabs in `RootTabView`, keyed by the `SPACES_MOBILE_SCREENSHOT_TAB` value.
private enum ScreenshotTab: String {
    case alerts
    case spaces
    case agents
    case settings

    /// The tab bar button's accessibility label. `RootTabView` sets no explicit identifier on its
    /// `.tabItem`s, so SwiftUI exposes each `Label`'s text as the tab bar button's label.
    var label: String {
        switch self {
        case .alerts: return "Alerts"
        case .spaces: return "Spaces"
        case .agents: return "Agents"
        case .settings: return "Settings"
        }
    }
}

/// The subset of the shared UI test config JSON (`SPACES_MOBILE_UI_TEST_CONFIG_PATH`, the same file
/// and env var `SpacesMobileUITests` reads) this test needs to pair against a running demo daemon.
/// Duplicated rather than shared because `UITestConfiguration` in `SpacesMobileUITests.swift` is
/// file-private and this file only needs the pairing fields — screenshot staging has no session ID
/// or scenario-specific fields to decode.
private struct ScreenshotUITestConfiguration: Decodable {
    static let defaultConfigPath = "/tmp/spaces-mobile-ui-test-config.json"

    let deviceID: String?
    let deviceName: String?
    let host: String
    let port: Int
    let authToken: String
    let certificateFingerprint: String
    let installationID: String

    /// Builds the same debug device-seed payload `SpacesMobileDeviceStore.applyDebugSeed` decodes,
    /// so a cold launch re-pairs against the same daemon the demo stack already paired.
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

    static func load(environment: [String: String]) throws -> Self {
        let configPath = environment["SPACES_MOBILE_UI_TEST_CONFIG_PATH"] ?? defaultConfigPath
        let url = URL(fileURLWithPath: configPath)
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ScreenshotUITestConfigurationError.missingConfigFile(configPath) }
        do { return try JSONDecoder().decode(Self.self, from: data) } catch {
            throw ScreenshotUITestConfigurationError.invalidConfigFile(configPath, error.localizedDescription)
        }
    }
}

private enum ScreenshotUITestConfigurationError: LocalizedError {
    case missingConfigFile(String)
    case invalidConfigFile(String, String)

    var errorDescription: String? {
        switch self {
        case .missingConfigFile(let path): return "Missing UI test config file at \(path)"
        case .invalidConfigFile(let path, let message): return "Invalid UI test config file at \(path): \(message)"
        }
    }
}
