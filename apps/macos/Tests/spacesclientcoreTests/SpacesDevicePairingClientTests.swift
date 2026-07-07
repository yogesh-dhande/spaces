import XCTest

@testable import spacesclientcore

final class SpacesDevicePairingClientTests: XCTestCase {
    func testLinuxInstallerRendersVersionPinnedOneLiner() {
        let command = SpacesLinuxInstaller.installCommand(version: "0.1.0")
        XCTAssertTrue(command.contains("releases/download/v0.1.0/spaces-install-linux.sh"))
        XCTAssertTrue(command.contains("bash -s -- 0.1.0"))
    }

    func testRemoteInstallProbeParsesLinuxPlatform() throws {
        let probe = try SpacesDevicePairingClient.parseRemoteInstallProbeOutput(
            """
            os=Linux
            arch=aarch64
            linux_id=ubuntu
            linux_version_id=24.04
            """, destination: "builder.local")

        XCTAssertEqual(
            probe, RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04"))
    }

    func testSSHPairingDeviceAPIHostUsesResolvedHostNameForAliases() throws {
        let configuration = SpacesDevicePairingClient.parseOpenSSHConfiguration(
            """
            user dev
            hostname 100.64.12.34
            port 2222
            """)

        let deviceAPIHost = try SpacesDevicePairingClient.sshPairingDeviceAPIHost(sshHost: "studio-mac", configuration: configuration)

        XCTAssertEqual(deviceAPIHost, "100.64.12.34")
    }

    func testSSHControlArgumentsReuseOneSocketPerDestination() {
        let args = SpacesDevicePairingClient.sshControlArguments(destination: "dev@studio-mac", port: 2222)
        XCTAssertEqual(args.first, "-o")
        let controlOption = try? XCTUnwrap(args.last)
        XCTAssertTrue(controlOption?.hasPrefix("ControlPath=") ?? false)

        // Same destination resolves to the same master socket so back-to-back commands multiplex.
        XCTAssertEqual(
            SpacesDevicePairingClient.sshControlPath(destination: "dev@studio-mac", port: 2222),
            SpacesDevicePairingClient.sshControlPath(destination: "dev@studio-mac", port: 2222))
        // Different targets never collide on one socket.
        XCTAssertNotEqual(
            SpacesDevicePairingClient.sshControlPath(destination: "dev@studio-mac", port: 2222),
            SpacesDevicePairingClient.sshControlPath(destination: "dev@studio-mac", port: 22))
        XCTAssertNotEqual(
            SpacesDevicePairingClient.sshControlPath(destination: "dev@studio-mac", port: nil),
            SpacesDevicePairingClient.sshControlPath(destination: "other@studio-mac", port: nil))

        // Stay well under the ~104-char AF_UNIX socket path limit.
        let socketPath = SpacesDevicePairingClient.sshControlPath(destination: "dev@studio-mac", port: 2222)
        XCTAssertLessThan(socketPath.utf8.count, 104)
        XCTAssertTrue(socketPath.hasSuffix(".sock"))
    }

    func testSSHConfigurationLookupUsesRemoteDestinationAndPort() {
        XCTAssertEqual(
            SpacesDevicePairingClient.sshConfigurationArguments(destination: "dev@studio-mac", port: 2222),
            [
                "-G", "-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
                "-p", "2222", "dev@studio-mac",
            ])
    }

    func testSSHPairingDeviceAPIHostFallsBackToNormalizedSSHHostWithoutHostName() throws {
        let configuration = SpacesDevicePairingClient.parseOpenSSHConfiguration(
            """
            user dev
            hostname none
            """)

        let deviceAPIHost = try SpacesDevicePairingClient.sshPairingDeviceAPIHost(sshHost: " studio.local ", configuration: configuration)

        XCTAssertEqual(deviceAPIHost, "studio.local")
    }

    func testRemotePairingWindowDeviceAPIHostUsesCurrentSSHAlias() throws {
        let configuration = SpacesDevicePairingClient.parseOpenSSHConfiguration(
            """
            hostname 100.64.12.34
            """)

        let deviceAPIHost = try SpacesDevicePairingClient.remotePairingWindowDeviceAPIHost(sshHost: "studio-mac", configuration: configuration)

        XCTAssertEqual(deviceAPIHost, "100.64.12.34")
    }

    func testRemotePairCommandFailureMessageIsUserFacing() {
        let message = SpacesDevicePairingClient.remotePairCommandFailureMessage(
            destination: "builder.local", standardError: "sh: 1: ~/.spaces/bin/spaces: not found", standardOutput: "", exitStatus: 127)

        XCTAssertFalse(message.contains("automatic setup"))
        XCTAssertFalse(message.contains("spacesd"))
        XCTAssertTrue(message.contains("builder.local"))
    }

    func testRemoteSpacesNotInstalledDetectsMissingBinaryOnFailedCommand() {
        XCTAssertTrue(
            SpacesDevicePairingClient.remoteSpacesNotInstalled(
                exitStatus: 127, standardError: "sh: 1: ~/.spaces/bin/spaces: not found", standardOutput: ""))
        XCTAssertTrue(
            SpacesDevicePairingClient.remoteSpacesNotInstalled(
                exitStatus: 1, standardError: "~/.spaces/bin/spaces: No such file or directory", standardOutput: ""))
    }

    func testRemoteSpacesNotInstalledIgnoresSuccessfulPairingJSON() {
        // A successful pair exits 0 with JSON that can legitimately contain "not found" (e.g. a device
        // name) — that must not be misread as a missing install.
        XCTAssertFalse(
            SpacesDevicePairingClient.remoteSpacesNotInstalled(
                exitStatus: 0, standardError: "",
                standardOutput: #"{"name":"Lost & not found Mac","host":"studio.local","port":8443}"#))
    }

    func testOutputReportsMissingBinaryDetectsShellNotFoundText() {
        // Tailscale SSH (and some other transports) return exit 0 even when the remote command failed, so
        // a missing `~/.spaces/bin/spaces` surfaces only as this stderr text. The content check must catch
        // both the macOS and Linux shell phrasings.
        XCTAssertTrue(SpacesDevicePairingClient.outputReportsMissingBinary("sh: /Users/x/.spaces/bin/spaces: No such file or directory"))
        XCTAssertTrue(SpacesDevicePairingClient.outputReportsMissingBinary("sh: 1: ~/.spaces/bin/spaces: not found"))
    }

    func testOutputReportsMissingBinaryIgnoresUnrelatedOutput() {
        XCTAssertFalse(SpacesDevicePairingClient.outputReportsMissingBinary(""))
        XCTAssertFalse(SpacesDevicePairingClient.outputReportsMissingBinary("could not reach spacesd control socket"))
    }

    func testRemoteSpacesNotInstalledStillIgnoresExitZeroToProtectPairingJSON() {
        // The exit-code path must never treat exit 0 as not-installed: a successful pair exits 0 with JSON
        // that can contain "not found" (e.g. a device name). The exit-0 case is instead handled by reading
        // stderr only when stdout carries no pairing JSON.
        XCTAssertFalse(
            SpacesDevicePairingClient.remoteSpacesNotInstalled(
                exitStatus: 0, standardError: "sh: ~/.spaces/bin/spaces: No such file or directory", standardOutput: ""))
    }

    func testInstallInstructionsMessageGuidesMacUserToInstallApp() {
        let probe = RemoteInstallProbe(operatingSystem: "Darwin", architecture: "arm64", linuxID: nil, linuxVersionID: nil)
        let message = SpacesDevicePairingClient.installInstructionsMessage(
            lead: "SSH connected to studio-mac, but Spaces there did not return a pairing window.",
            probe: probe, appVersion: "0.1.0")

        XCTAssertTrue(message.contains("studio-mac"))
        XCTAssertTrue(message.contains("Install the Spaces app on the remote Mac"))
        XCTAssertTrue(message.contains("open it once"))
        // Mac users install the app, not the Linux one-liner.
        XCTAssertFalse(message.contains("spaces-install-linux.sh"))
    }

    func testInstallInstructionsMessageGivesLinuxUserVersionPinnedInstaller() {
        let probe = RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04")
        let message = SpacesDevicePairingClient.installInstructionsMessage(
            lead: "SSH connected to builder.local, but Spaces there did not return a pairing window.",
            probe: probe, appVersion: "0.1.0")

        XCTAssertTrue(message.contains("builder.local"))
        XCTAssertTrue(message.contains("Ubuntu 24.04 device"))
        XCTAssertTrue(message.contains(SpacesLinuxInstaller.installCommand(version: "0.1.0")))
    }

    func testInstallInstructionsMessageFallsBackToLatestWhenAppVersionMissing() {
        let probe = RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04")
        let message = SpacesDevicePairingClient.installInstructionsMessage(
            lead: "SSH connected to builder.local, but Spaces is not installed for that user.",
            probe: probe, appVersion: nil)

        XCTAssertTrue(message.contains(SpacesLinuxInstaller.installCommand(version: "latest")))
    }

    func testRemoteShellCommandRunsSnippetsThroughPOSIXShell() {
        let wrapped = SpacesDevicePairingClient.remoteShellCommand("printf 'ok'\nuname -s")

        XCTAssertTrue(wrapped.hasPrefix("sh -c '"))
        XCTAssertTrue(wrapped.hasSuffix("'"))
        XCTAssertFalse(wrapped.hasPrefix("sh -lc "))
        XCTAssertTrue(wrapped.contains("printf '\\''ok'\\''"))
        XCTAssertTrue(wrapped.contains("\nuname -s"))
    }

    func testLinuxArtifactInstallerEnablesLingeringBeforeStartingService() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_linux_spacesd_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let lingerRange = try XCTUnwrap(script.range(of: "ensure_user_linger"))
        let restartRange = try XCTUnwrap(script.range(of: "systemctl --user restart spacesd.service"))
        XCTAssertLessThan(lingerRange.lowerBound, restartRange.lowerBound)
        XCTAssertTrue(script.contains("loginctl enable-linger"))
        XCTAssertTrue(script.contains("keep background services running after SSH disconnects"))
    }

    func testLinuxArtifactInstallerKeepsSpacesAndDaemonInSameRelease() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_linux_spacesd_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains(#"ln -sfn "$release_dir/bin/spacesd" "$bin_root/spacesd""#))
        XCTAssertTrue(script.contains(#"ln -sfn "$release_dir/bin/spaces" "$bin_root/spaces""#))
        XCTAssertTrue(script.contains("ExecStart=%h/.spaces/bin/spacesd"))
        XCTAssertTrue(script.contains("systemctl --user restart spacesd.service"))
    }

    func testLinuxArtifactInstallerCreatesUserPathAlias() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_linux_spacesd_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains(#"user_bin_root="$HOME/.local/bin""#))
        XCTAssertTrue(script.contains(#"ln -sfn "$bin_root/spaces" "$user_bin_root/spaces""#))
        XCTAssertTrue(script.contains(#""path_aliases": ["~/.local/bin/spaces"],"#))
    }

    func testDMGInstallerUsesAppResourcesAsCanonicalMacBinarySource() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/create-dmg.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains(#"CLI_TARGET="$APP_RESOURCE_DIR/spaces""#))
        XCTAssertTrue(script.contains(#"SERVICE_TARGET="$APP_RESOURCE_DIR/spacesd""#))
        XCTAssertTrue(script.contains(#"CADDY_TARGET="$APP_RESOURCE_DIR/caddy""#))
        XCTAssertTrue(script.contains(#"/bin/ln -sfn "$CLI_TARGET" "$CLI_PATH""#))
        XCTAssertTrue(script.contains(#"/bin/ln -sfn "$SERVICE_TARGET" "$SERVICE_PATH""#))
        XCTAssertTrue(script.contains(#"/bin/ln -sfn "$CADDY_TARGET" "$CADDY_PATH""#))
        XCTAssertTrue(script.contains(#"/bin/ln -sfn "$cli_target" "$bin_dir/spaces""#))
        XCTAssertTrue(script.contains(#"/bin/ln -sfn "$daemon_target" "$bin_dir/spacesd""#))
        XCTAssertTrue(script.contains(#"LAUNCH_SERVICE_PATH="$INSTALL_HOME/.spaces/bin/spacesd""#))
        XCTAssertTrue(script.contains(#"install_launch_agent "$LAUNCH_SERVICE_PATH""#))
    }

    func testRemoteDeviceE2EDoesNotKeepSSHSessionAliveForLinuxService() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "e2e_remote_device_api.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertFalse(script.contains("REMOTE_KEEPALIVE_PID"))
        XCTAssertFalse(script.contains("start_remote_systemd_keepalive"))
        XCTAssertTrue(script.contains("wait_for_remote_daemon_from_mac"))
        XCTAssertTrue(script.contains("survives SSH setup disconnect"))
    }

    func testMobileDemoPreparesRepoLocalLinuxArtifactBeforeRemotePairing() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "run_mobile_terminal_demo.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let prepareRange = try XCTUnwrap(script.range(of: "  prepare_remote_demo_daemon"))
        let pairRange = try XCTUnwrap(script.range(of: #""$spacese2e" "${args[@]}" >"$remote_pairing_json""#))
        XCTAssertLessThan(prepareRange.lowerBound, pairRange.lowerBound)
        XCTAssertTrue(script.contains("deploy_linux_spacesd_e2e.sh"))
        XCTAssertTrue(script.contains("SPACES_DEVICE_API_PORT=$remote_demo_daemon_port"))
        XCTAssertTrue(script.contains("~/.spaces/bin/spaces mobile status"))
    }

    func testDevBuildLaunchVerifiesLinuxUserPathAlias() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/dev-build-and-launch.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("~/.local/bin/spaces mobile status"))
    }

    func testRemotePairingSSHValidationMessagesAreActionable() {
        let unknownHost = SpacesDevicePairingClient.sshValidationFailureMessage(
            destination: "builder.local",
            detail: "No ED25519 host key is known for builder.local and you have requested strict checking.\nHost key verification failed.",
            exitStatus: 255)
        XCTAssertTrue(unknownHost.contains("StrictHostKeyChecking=yes"))
        XCTAssertTrue(unknownHost.contains("known_hosts"))

        let authFailure = SpacesDevicePairingClient.sshValidationFailureMessage(
            destination: "dev@builder.local", detail: "Permission denied (publickey).", exitStatus: 255)
        XCTAssertTrue(authFailure.contains("BatchMode=yes"))
        XCTAssertTrue(authFailure.contains("key-based SSH access"))

        let changedHostKey = SpacesDevicePairingClient.sshValidationFailureMessage(
            destination: "builder.local", detail: "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", exitStatus: 255)
        XCTAssertTrue(changedHostKey.contains("known_hosts entry changed"))
    }
}
