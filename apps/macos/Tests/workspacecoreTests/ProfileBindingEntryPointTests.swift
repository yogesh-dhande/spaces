import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// A profile's identity is where its binary sits, so an inherited `SPACES_DB_PATH`/`SPACES_RUNTIME_DIR` at a
/// developer entry point is never wanted — and is harmful in both directions. Pointing inside a live profile
/// root, resolution refuses it and the script dies under `set -e`; pointing at an unrelated throwaway root,
/// the whole run silently retargets onto a profile nobody asked for. `verify-prep.sh` is the sharp end: it
/// gates every commit, so an abort there stops both test lanes before either runs.
///
/// These are shell entry points, so the mechanism is exercised by running the real helper under `bash` and
/// the call sites are pinned by reading the scripts — the same shape as `InstallerScriptDriftTests`. Running
/// the entry points themselves end to end is not cheap enough to automate: `verify-prep.sh` is a full lint,
/// build, and release-signing pass, and `dev-build-and-launch.sh` launches the app and can deploy to a remote
/// device.
final class ProfileBindingEntryPointTests: XCTestCase {

    /// The mechanism itself, against the real helper: a shell carrying a live-root binding has both variables
    /// gone afterward. A live root is used deliberately because that is the value that would otherwise abort
    /// the caller rather than merely misdirect it.
    func testClearHelperRemovesAnInheritedLiveRootBinding() throws {
        let accountHome = try XCTUnwrap(SpacesProfile.accountHomeDirectoryPath())
        let liveRoot = "\(accountHome)/.spaces-dev/profiles/spaces/inherited-abc123def456"

        let output = try runBash(
            """
            set -euo pipefail
            source \(Self.shellQuoted(Self.repoRootURL.appendingPathComponent("scripts/spaces-profile-helpers.sh").path))
            spaces_profile_clear_inherited_binding
            printf 'db=%s runtime=%s\\n' "${SPACES_DB_PATH:-<cleared>}" "${SPACES_RUNTIME_DIR:-<cleared>}"
            """, environment: ["SPACES_DB_PATH": "\(liveRoot)/spaces.db", "SPACES_RUNTIME_DIR": "\(liveRoot)/runtime"])

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "db=<cleared> runtime=<cleared>")
    }

    /// Clearing has to happen before anything resolves a profile, or the entry point has already acted on the
    /// inherited one. Asserting the order rather than mere presence is the point: a call placed after the
    /// first lookup would satisfy a `contains` check and still leave the bug.
    func testEveryEntryPointClearsBeforeItResolvesAProfile() throws {
        // Each entry point paired with the first thing in it that resolves or acts on a profile.
        let entryPoints: [(path: String, firstProfileUse: String)] = [
            ("scripts/dev-build-and-launch.sh", "spaces_profile_field"),
            ("apps/macos/scripts/verify-prep.sh", "stop_current_profile_runtime_for_tests\n"),
            ("apps/macos/Tests/e2e_agent_orchestration.sh", "profile-show --json"),
            ("apps/macos/Tests/run_mobile_terminal_demo.sh", "run_demo_env()"),
        ]

        for entryPoint in entryPoints {
            let script = try String(contentsOf: Self.repoRootURL.appendingPathComponent(entryPoint.path), encoding: .utf8)
            let clearIndex = try XCTUnwrap(
                script.range(of: "spaces_profile_clear_inherited_binding\n")?.lowerBound,
                "\(entryPoint.path) must clear an inherited profile binding.")
            let useIndex = try XCTUnwrap(
                script.range(of: entryPoint.firstProfileUse)?.lowerBound,
                "\(entryPoint.path) no longer contains \(entryPoint.firstProfileUse); update this test's anchor.")
            XCTAssertLessThan(clearIndex, useIndex, "\(entryPoint.path) must clear the inherited binding before \(entryPoint.firstProfileUse).")
        }
    }

    /// The clear must not take the deliberate throwaway profile with it. `SPACES_DEV_DB_PATH` is applied
    /// after the clear, so a developer asking for a scratch root still gets one while an inherited binding
    /// cannot survive.
    func testDevBuildLaunchAppliesItsThrowawayProfileAfterClearing() throws {
        let script = try String(contentsOf: Self.repoRootURL.appendingPathComponent("scripts/dev-build-and-launch.sh"), encoding: .utf8)
        let clearIndex = try XCTUnwrap(script.range(of: "spaces_profile_clear_inherited_binding\n")?.lowerBound)
        let applyIndex = try XCTUnwrap(script.range(of: #"export SPACES_DB_PATH="$SPACES_DEV_DB_PATH""#)?.lowerBound)
        XCTAssertLessThan(clearIndex, applyIndex, "SPACES_DEV_DB_PATH must be applied after the clear, or the clear would erase it.")
    }

    /// The mobile demo's isolated mode names its own ephemeral root, which is the one thing that mode is for,
    /// and it does so through `demo_profile_env` rather than by inheriting — so clearing at the top cannot
    /// take it away.
    func testMobileDemoIsolatedModeStillNamesItsEphemeralProfile() throws {
        let script = try String(contentsOf: Self.repoRootURL.appendingPathComponent("apps/macos/Tests/run_mobile_terminal_demo.sh"), encoding: .utf8)
        let clearIndex = try XCTUnwrap(script.range(of: "spaces_profile_clear_inherited_binding\n")?.lowerBound)
        let assignIndex = try XCTUnwrap(
            script.range(of: #"demo_profile_env=(SPACES_DB_PATH="$spaces_db_path" SPACES_RUNTIME_DIR="$spaces_runtime_dir")"#)?.lowerBound)
        XCTAssertLessThan(clearIndex, assignIndex)
    }

    private func runBash(_ script: String, environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The shell snippet failed.")
        return String(decoding: data, as: UTF8.self)
    }

    private static func shellQuoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // workspacecoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .deletingLastPathComponent()  // apps
            .deletingLastPathComponent()  // repo root
    }
}
