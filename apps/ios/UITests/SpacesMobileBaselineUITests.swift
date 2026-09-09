import Foundation
import XCTest

/// On-demand performance-lane scenarios driven by `apps/macos/Tests/e2e_mobile_baseline.sh` against a
/// live daemon (this worktree's local dev daemon, or its remote Linux dev profile) through a Mac-side
/// shaping proxy (`apps/macos/Tests/ios_baseline_shaper.py`). Never run by `scripts/verify.sh` or CI: the
/// runner invokes one `xcodebuild ... test-without-building -only-testing:` per scenario per network
/// profile, each time with a fresh `BaselineLaneConfiguration` at `SPACES_MOBILE_BASELINE_CONFIG_PATH`.
///
/// Every test launches with `SPACES_MOBILE_TEST_FIXED_HOSTS=1`, which makes
/// `SpacesMobileDeviceStore.mergeAdvertisedHosts` a no-op so the seeded shaping-proxy address
/// (127.0.0.1) stays the paired device's only host for the run: without it, the daemon's own advertised
/// LAN/tailnet addresses would race the deliberately delayed proxy in `SpacesDeviceEndpointResolver` and
/// win, silently bypassing the shaping this lane exists to measure.
///
/// Each test appends `lane_marker` lines into the run's shared `device-perf.jsonl`
/// (`BaselineLaneMarkers`) so the runner's report can slice this scenario's window out of that one
/// stream, alongside the app's own performance events. No test asserts on timing: the lane measures, it
/// does not gate, so every assertion here is about the flow succeeding (an element appearing, the
/// keyboard coming up, the reconnect banner clearing), never about how long that took.
final class SpacesMobileBaselineUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testColdOpen() throws { try runScenario(coldOpen) }
    func testBackAndForth() throws { try runScenario(backAndForth) }
    func testKeyboard() throws { try runScenario(keyboard) }
    func testStreaming() throws { try runScenario(streaming) }
    func testScrollback() throws { try runScenario(scrollback) }
    func testBackgroundForegroundTerminal() throws { try runScenario(backgroundForegroundTerminal) }
    func testBackgroundForegroundList() throws { try runScenario(backgroundForegroundList) }
    func testReconnect() throws { try runScenario(reconnect) }
    func testIdle() throws { try runScenario(idle) }

    // MARK: - Launch and marker plumbing

    /// One scenario run: loads the config, launches the app pinned to the shaping proxy, brackets the
    /// scenario body with `scenario_begin`/`scenario_end` lane markers, and runs it.
    private func runScenario(_ body: (ScenarioContext) throws -> Void) throws {
        let configuration = try BaselineLaneConfiguration.load(environment: ProcessInfo.processInfo.environment)

        var environment: [String: String] = [
            "SPACES_MOBILE_TEST_INSTALLATION_ID": configuration.installationID, "SPACES_MOBILE_TEST_FIXED_HOSTS": "1",
            "SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH": configuration.perfLogPath,
        ]
        // The E2E render dump is a pretty-printed atomic file write on the main actor for every frame
        // of the target session, which would inflate every measured scenario. Only streaming needs it
        // (it is the sole way to see `AGENT_SCREEN_READY` / `BURST_DONE` on a Metal-rendered surface),
        // so only streaming pays for it; its section in the report carries that caveat.
        if configuration.scenario == "streaming" {
            environment["SPACES_MOBILE_E2E_TARGET_SESSION_ID"] = configuration.sessionID
            environment["SPACES_MOBILE_E2E_RENDER_DUMP_PATH"] = renderDumpPath(for: configuration)
        }
        if let deviceSeedJSON = configuration.deviceSeedJSON { environment["SPACES_MOBILE_TEST_DEVICE_SEED_JSON"] = deviceSeedJSON }

        // Not `SpacesMobileUITestDriver.launchApp`: its clean-slate launch arguments put `unset` in the
        // defaults argument domain for the paired-devices key, which shadows the device the seed writes
        // to the persistent domain, and the app then lands on "Pair This Device".
        let app = XCUIApplication()
        app.launchEnvironment["SPACES_MOBILE_PAYWALL_BYPASS"] = "1"
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let context = ScenarioContext(app: app, configuration: configuration)
        context.mark("scenario_begin")
        defer { context.mark("scenario_end") }
        try body(context)
    }

    /// Bundles the launched app and its configuration so scenario bodies and the marker helper below
    /// share one value instead of threading four parameters through every scenario function.
    private struct ScenarioContext {
        let app: XCUIApplication
        let configuration: BaselineLaneConfiguration

        func mark(_ marker: String, _ extraAttributes: [String: String] = [:]) {
            BaselineLaneMarkers.write(
                marker: marker, profile: configuration.profile, scenario: configuration.scenario, extraAttributes: extraAttributes,
                perfLogPath: configuration.perfLogPath)
        }
    }

    /// Scratch path for this run's render-dump polling (`SPACES_MOBILE_E2E_RENDER_DUMP_PATH`), next to
    /// the shared perf log rather than in it: unlike `device-perf.jsonl`, this file is overwritten on
    /// every frame by the app and is not part of the run root's documented output, so it lives under a
    /// scenario/profile-specific name purely so this test can poll it without a second scenario's app
    /// process racing to overwrite the same file mid-run.
    private func renderDumpPath(for configuration: BaselineLaneConfiguration) -> String {
        let directory = (configuration.perfLogPath as NSString).deletingLastPathComponent
        return "\(directory)/render-dump-\(configuration.profile)-\(configuration.scenario).json"
    }

    // MARK: - Shared waits

    private func waitForList(_ context: ScenarioContext, timeout: TimeInterval = 20) {
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForElement(identifier: "terminal.row.\(context.configuration.sessionID)", in: context.app, timeout: timeout),
            "Timed out waiting for the terminal list")
    }

    /// Waits without scrolling. The driver's scrolling wait swipes the screen while it polls, and once the
    /// detail view is up those swipes land on the terminal surface as scroll gestures: each one becomes a
    /// scroll round trip to the daemon and postpones the viewport report the first paint waits on, which
    /// under the poor profile moves the measured open by seconds. The surface is never below the fold.
    private func waitForSurface(_ context: ScenarioContext, timeout: TimeInterval = 20) {
        XCTAssertTrue(
            context.app.descendants(matching: .any)["terminal.surface"].waitForExistence(timeout: timeout),
            "Timed out waiting for the terminal surface")
    }

    private func openFixtureSession(_ context: ScenarioContext) {
        waitForList(context)
        SpacesMobileUITestDriver.openTerminalRow(sessionID: context.configuration.sessionID, in: context.app)
        waitForSurface(context)
    }

    // MARK: - Scenario 1: cold-open

    private func coldOpen(_ context: ScenarioContext) throws {
        waitForList(context)
        context.mark("open_tap")
        SpacesMobileUITestDriver.openTerminalRow(sessionID: context.configuration.sessionID, in: context.app)
        waitForSurface(context)
        context.mark("first_paint_seen")
        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - Scenario 2: back-and-forth

    private func backAndForth(_ context: ScenarioContext) throws {
        let reopenCount = context.configuration.reopenCount
        guard reopenCount > 0 else { return }

        openFixtureSession(context)  // warm open, not measured
        for iteration in 1...reopenCount {
            context.mark("back_tap", ["iteration": String(iteration)])
            SpacesMobileUITestDriver.leaveTerminalDetail(in: context.app)
            waitForList(context, timeout: 15)

            context.mark("open_tap", ["iteration": String(iteration)])
            SpacesMobileUITestDriver.openTerminalRow(sessionID: context.configuration.sessionID, in: context.app)
            waitForSurface(context, timeout: 15)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // MARK: - Scenario 3: keyboard

    private func keyboard(_ context: ScenarioContext) throws {
        let keyboardCycles = context.configuration.keyboardCycles
        guard keyboardCycles > 0 else { return }

        openFixtureSession(context)
        for cycle in 1...keyboardCycles {
            context.mark("keyboard_show_tap", ["cycle": String(cycle)])
            // The first show comes from tapping the surface. Once the accessory toggle has hidden the
            // keyboard the surface stays first responder with the keyboard suppressed, so a surface tap
            // cannot bring it back; a user taps the same accessory toggle again, and so does this test.
            if cycle == 1 {
                SpacesMobileUITestDriver.focusTerminalSurface(in: context.app)
            } else {
                SpacesMobileUITestDriver.tapKeyboardAccessoryToggle(in: context.app, timeout: 5)
            }
            XCTAssertTrue(
                SpacesMobileUITestDriver.waitForKeyboard(in: context.app, timeout: 10), "Timed out waiting for the keyboard on cycle \(cycle)")

            context.app.typeText("echo hi\n")
            context.mark("typed", ["cycle": String(cycle)])

            SpacesMobileUITestDriver.tapKeyboardAccessoryToggle(in: context.app, timeout: 5)
            context.mark("keyboard_hide_tap", ["cycle": String(cycle)])
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    // MARK: - Scenario 4: streaming

    /// Waits for `AGENT_SCREEN_READY`/`BURST_DONE n` through the app's E2E render-dump mechanism (see
    /// `SpacesMobileUITestDriver.waitForRenderedText`), the same one the takeover UI tests use to read
    /// terminal content: the surface is a Metal view with no accessible text. A marker that never shows
    /// up fails the scenario rather than being guessed at with a fixed hold.
    private func streaming(_ context: ScenarioContext) throws {
        openFixtureSession(context)
        let renderDumpPath = renderDumpPath(for: context.configuration)

        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForRenderedText(
                containing: "AGENT_SCREEN_READY", sessionID: context.configuration.sessionID, renderDumpPath: renderDumpPath, timeout: 30),
            "The agent screen never rendered")
        context.mark("streaming_ready")

        for burst in 1...2 {
            XCTAssertTrue(
                SpacesMobileUITestDriver.waitForRenderedText(
                    containing: "BURST_DONE \(burst)", sessionID: context.configuration.sessionID, renderDumpPath: renderDumpPath, timeout: 60),
                "Burst \(burst) never finished on screen")
            context.mark("burst_wait_end", ["burst": String(burst)])
        }
    }

    // MARK: - Scenario 5: scrollback

    private func scrollback(_ context: ScenarioContext) throws {
        openFixtureSession(context)
        Thread.sleep(forTimeInterval: 3)
        SpacesMobileUITestDriver.focusTerminalSurface(in: context.app)

        let flickCount = context.configuration.flickCount
        if flickCount > 0 {
            for index in 1...flickCount {
                context.mark("flick", ["index": String(index), "direction": "down"])
                SpacesMobileUITestDriver.flickTerminalSurface(.towardHistory, in: context.app)
                Thread.sleep(forTimeInterval: 2)
            }
        }

        // Fixed at 4, not driven by a separate config field: the contract asks for "4 flicks back toward
        // the bottom" regardless of how many flicks `flickCount` sent into history.
        let returnFlickCount = 4
        for index in 1...returnFlickCount {
            context.mark("flick", ["index": String(index), "direction": "up"])
            SpacesMobileUITestDriver.flickTerminalSurface(.towardBottom, in: context.app)
            Thread.sleep(forTimeInterval: 2)
        }
    }

    // MARK: - Scenario 6: background-terminal

    private func backgroundForegroundTerminal(_ context: ScenarioContext) throws {
        let backgroundCycles = context.configuration.backgroundCycles
        guard backgroundCycles > 0 else { return }

        openFixtureSession(context)
        Thread.sleep(forTimeInterval: 2)
        for iteration in 1...backgroundCycles {
            context.mark("background", ["iteration": String(iteration)])
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 5)

            context.mark("foreground", ["iteration": String(iteration)])
            context.app.activate()
            waitForSurface(context, timeout: 15)
            Thread.sleep(forTimeInterval: 3)
        }
    }

    // MARK: - Scenario 7: background-list

    private func backgroundForegroundList(_ context: ScenarioContext) throws {
        let backgroundCycles = context.configuration.backgroundCycles
        guard backgroundCycles > 0 else { return }

        waitForList(context)
        for iteration in 1...backgroundCycles {
            context.mark("background", ["iteration": String(iteration)])
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: 5)

            context.mark("foreground", ["iteration": String(iteration)])
            context.app.activate()
            waitForList(context, timeout: 15)
            Thread.sleep(forTimeInterval: 3)
        }
    }

    // MARK: - Scenario 8: reconnect

    private func reconnect(_ context: ScenarioContext) throws {
        openFixtureSession(context)
        Thread.sleep(forTimeInterval: 3)

        context.mark("link_down")
        XCTAssertNotNil(
            ShaperControlClient.send(command: "link down", port: context.configuration.shaperControlPort), "Shaper control did not answer link down")

        let banner = context.app.descendants(matching: .any)["terminal.connectionBanner"]
        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForElement(identifier: "terminal.connectionBanner", in: context.app, timeout: 20),
            "The reconnecting banner did not appear within 20s of link down")
        context.mark("banner_seen")
        Thread.sleep(forTimeInterval: 10)

        context.mark("link_up")
        XCTAssertNotNil(
            ShaperControlClient.send(command: "link up", port: context.configuration.shaperControlPort), "Shaper control did not answer link up")

        XCTAssertTrue(
            SpacesMobileUITestDriver.waitForDisappearance(of: banner, timeout: 60), "The reconnecting banner did not clear within 60s of link up")
        context.mark("recovered")
        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - Scenario 9: idle

    private func idle(_ context: ScenarioContext) throws {
        openFixtureSession(context)
        context.mark("idle_begin")
        sleepInChunks(seconds: context.configuration.idleSeconds)
        context.mark("idle_end")
    }

    /// Sleeps `seconds` in 30s chunks, printing progress between chunks so a long idle run's console log
    /// shows it is still alive rather than looking hung.
    private func sleepInChunks(seconds: Int) {
        var remaining = seconds
        while remaining > 0 {
            let chunk = min(30, remaining)
            Thread.sleep(forTimeInterval: TimeInterval(chunk))
            remaining -= chunk
            print("[baseline] idle: \(seconds - remaining)s / \(seconds)s elapsed")
        }
    }
}
