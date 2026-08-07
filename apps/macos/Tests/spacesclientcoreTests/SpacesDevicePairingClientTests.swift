import XCTest

@testable import spacesclientcore
@testable import spacesterminalcore

final class SpacesDevicePairingClientTests: XCTestCase {
    func testLinuxInstallerRendersVersionPinnedOneLiner() {
        XCTAssertEqual(SpacesLinuxInstaller.installCommand(version: "0.1.0"), "curl -fsSL https://usespaces.dev/install.sh | bash -s -- 0.1.0")
        // A leading `v` is stripped so the pinned argument matches the release's app_version.
        XCTAssertEqual(SpacesLinuxInstaller.installCommand(version: "v0.1.0"), "curl -fsSL https://usespaces.dev/install.sh | bash -s -- 0.1.0")
    }

    func testLinuxInstallerRendersEvergreenOneLinerWithoutVersion() {
        let evergreen = "curl -fsSL https://usespaces.dev/install.sh | bash"
        XCTAssertEqual(SpacesLinuxInstaller.installCommand(version: nil), evergreen)
        XCTAssertEqual(SpacesLinuxInstaller.installCommand(version: ""), evergreen)
        // The evergreen form installs the latest release with no pinned argument and no "latest" literal.
        for command in [SpacesLinuxInstaller.installCommand(version: nil), SpacesLinuxInstaller.installCommand(version: "")] {
            XCTAssertFalse(command.contains("-s --"))
            XCTAssertFalse(command.lowercased().contains("latest"))
        }
    }

    func testSSHInstallCommandPropagatesDownloadFailures() {
        // The SSH recovery form must download-then-execute, never pipe curl into bash: under the
        // remote `sh -c` wrapper a pipeline exits with bash's status (0 on an empty stream), which
        // would report a failed install.sh download as a successful install.
        for version in ["0.1.0", "v0.1.0"] {
            XCTAssertEqual(
                SpacesLinuxInstaller.sshInstallCommand(version: version),
                #"set -e; installer="$(mktemp)"; trap 'rm -f "$installer"' EXIT; curl -fsSL https://usespaces.dev/install.sh -o "$installer"; bash "$installer" 0.1.0"#
            )
        }
        for command in [SpacesLinuxInstaller.sshInstallCommand(version: nil), SpacesLinuxInstaller.sshInstallCommand(version: "")] {
            XCTAssertEqual(
                command,
                #"set -e; installer="$(mktemp)"; trap 'rm -f "$installer"' EXIT; curl -fsSL https://usespaces.dev/install.sh -o "$installer"; bash "$installer""#
            )
        }
    }

    func testRemoteInstallProbeParsesLinuxPlatform() throws {
        let probe = try SpacesDevicePairingClient.parseRemoteInstallProbeOutput(
            """
            os=Linux
            arch=aarch64
            linux_id=ubuntu
            linux_version_id=24.04
            """, destination: "builder.local")

        XCTAssertEqual(probe, RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04"))
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

    /// The relayed QR link (`openRemotePairingWindow`) must lead with the SSH-resolved host — the one
    /// address this Mac has actually proven routable — and still carry the remote daemon's own
    /// advertised addresses (e.g. its tailnet address), since the phone scanning the code is a
    /// different device from this Mac and may not share its SSH route.
    func testRelayedPairingHostsLeadsWithSSHResolvedHostFollowedByAdvertisedHosts() {
        XCTAssertEqual(
            SpacesDevicePairingClient.relayedPairingHosts(deviceAPIHost: "studio.local", advertisedHosts: ["10.0.0.5", "100.64.12.34"]),
            ["studio.local", "10.0.0.5", "100.64.12.34"])
    }

    /// A daemon that happens to advertise the same address the SSH resolution already produced (a
    /// common case: SSH resolved straight to the daemon's LAN IPv4) must not be listed twice.
    func testRelayedPairingHostsDeduplicatesAgainstTheSSHResolvedHost() {
        XCTAssertEqual(
            SpacesDevicePairingClient.relayedPairingHosts(deviceAPIHost: "10.0.0.5", advertisedHosts: ["10.0.0.5", "100.64.12.34"]),
            ["10.0.0.5", "100.64.12.34"])
    }

    /// A remote daemon that has not (yet) reported any addresses of its own must still yield a usable
    /// single-host link off the SSH-resolved address alone.
    func testRelayedPairingHostsFallsBackToSSHResolvedHostAloneWhenNoneAdvertised() {
        XCTAssertEqual(SpacesDevicePairingClient.relayedPairingHosts(deviceAPIHost: "studio.local", advertisedHosts: []), ["studio.local"])
    }

    /// A device's stored id must not move when the address it was paired on changes, and no stored id
    /// is ever rewritten, because the id has always been decided by the certificate fingerprint alone:
    /// the 48-character truncation lands inside the fingerprint hex, so the host and port in the old
    /// formula could never reach the output. Pins that against the historical formula for a realistic
    /// fingerprint.
    func testStablePairedDeviceIDMatchesTheHistoricalHostBearingFormula() {
        let fingerprint = "SHA256:" + String(repeating: "a1b2c3d4", count: 8)
        XCTAssertEqual(fingerprint.count, "SHA256:".count + 64)

        func historicalID(certificateFingerprint: String, host: String, port: Int) -> String {
            let source = "\(certificateFingerprint)|\(host)|\(port)"
            let slug = source.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression).trimmingCharacters(
                in: CharacterSet(charactersIn: "-"))
            return "device-\(slug.prefix(48))"
        }

        for host in ["studio.local", "10.0.0.5", "100.64.12.34"] {
            XCTAssertEqual(
                SpacesDevicePairingClient.stablePairedDeviceID(certificateFingerprint: fingerprint, port: 47_847),
                historicalID(certificateFingerprint: fingerprint, host: host, port: 47_847))
        }
    }

    func testRemotePairCommandFailureMessageIsUserFacing() {
        let message = SpacesDevicePairingClient.remotePairCommandFailureMessage(
            destination: "builder.local", command: SpacesDevicePairingClient.installedRemotePairCommand,
            standardError: "sh: 1: ~/.spaces/bin/spaces: not found", standardOutput: "", exitStatus: 127)

        XCTAssertFalse(message.contains("automatic setup"))
        XCTAssertFalse(message.contains("spacesd"))
        XCTAssertTrue(message.contains("builder.local"))
    }

    func testRemotePairCommandUsesInstalledProfileCommandByDefault() throws {
        let profile = SpacesProfile(
            source: .installedFallback, databasePath: "/Users/tester/.spaces/spaces.db", rootDirectory: "/Users/tester/.spaces",
            isInstalledProfile: true, runtimeDirectory: "/Users/tester/.spaces/runtime", ipcNotificationObject: "spaces.profile.installed",
            developmentContext: nil, branchSlug: nil, worktreeHash: nil)

        let pairCommand = try SpacesDevicePairingClient.remotePairCommand(profile: profile)
        XCTAssertEqual(pairCommand.command, SpacesDevicePairingClient.installedRemotePairCommand)
        XCTAssertNil(pairCommand.developmentProfileName)
    }

    /// A development profile pairs through its own deployed CLI inside the matching remote profile root,
    /// with no environment prefix: that binary resolves its own profile from where it lives, so pairing
    /// never points the installed CLI at a development database.
    func testRemotePairCommandTargetsMatchingRemoteDevelopmentProfile() throws {
        let profileName = "schema-squash-v1-154418a8e022"
        let root = "/Users/tester/.spaces-dev/profiles/spaces/\(profileName)"
        let profile = SpacesProfile(
            source: .explicitDatabasePath, databasePath: "\(root)/spaces.db", rootDirectory: root, isInstalledProfile: false,
            runtimeDirectory: "\(root)/runtime", ipcNotificationObject: "spaces.profile.dev", developmentContext: nil, branchSlug: nil,
            worktreeHash: nil)

        let pairCommand = try SpacesDevicePairingClient.remotePairCommand(profile: profile)
        XCTAssertEqual(
            pairCommand.command, #""$HOME/.spaces-dev/profiles/spaces/schema-squash-v1-154418a8e022/daemon/current/bin/spaces" device pair --json"#)
        XCTAssertEqual(pairCommand.developmentProfileName, profileName)
        XCTAssertFalse(pairCommand.command.contains(SpacesProfile.databasePathEnvironmentVariable))
        XCTAssertFalse(pairCommand.command.contains(SpacesProfile.runtimeDirectoryEnvironmentVariable))
    }

    /// A development profile whose CLI is missing on the device must never be reported as "Spaces is not
    /// installed": that error carries the production installer one-liner and drives the app's "Install
    /// Spaces over SSH" affordance, which installs only `~/.spaces` and therefore could never make this
    /// pairing succeed. The actionable answer is to deploy this worktree's profile to the device.
    func testMissingDevelopmentProfileCLIReportsAnUndeployedProfileInsteadOfAMissingInstall() throws {
        let probe = RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04")
        let pairCommand = RemotePairCommand(
            command: #""$HOME/.spaces-dev/profiles/spaces/feature-x-0123456789ab/daemon/current/bin/spaces" device pair --json"#,
            developmentProfileName: "feature-x-0123456789ab")

        let error = SpacesDevicePairingClient.remotePairCommandBinaryMissingError(
            destination: "builder.local", pairCommand: pairCommand, probe: probe, appVersion: "0.1.0")

        guard case .remoteDevelopmentProfileNotDeployed = error else { return XCTFail("expected remoteDevelopmentProfileNotDeployed, got \(error).") }
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("builder.local"))
        XCTAssertTrue(message.contains("feature-x-0123456789ab"))
        XCTAssertTrue(message.contains("scripts/dev-build-and-launch.sh"))
        // No install one-liner and no install guidance: neither would deploy this profile.
        XCTAssertFalse(message.contains("install.sh"))
        XCTAssertFalse(message.contains("not installed"))
    }

    /// The installed profile's missing CLI keeps the not-installed error exactly as it was, install command
    /// and affordance included: that device really has no Spaces, and the installer is the way through.
    func testMissingInstalledCLIStillReportsNotInstalledWithTheInstallCommand() throws {
        let probe = RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04")
        let pairCommand = RemotePairCommand(command: SpacesDevicePairingClient.installedRemotePairCommand, developmentProfileName: nil)

        let error = SpacesDevicePairingClient.remotePairCommandBinaryMissingError(
            destination: "builder.local", pairCommand: pairCommand, probe: probe, appVersion: "0.1.0")

        guard case .remoteSpacesNotInstalled(_, let installCommand) = error else {
            return XCTFail("expected remoteSpacesNotInstalled, got \(error).")
        }
        XCTAssertEqual(installCommand, "curl -fsSL https://usespaces.dev/install.sh | bash -s -- 0.1.0")
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("Spaces is not installed for that user"))
        XCTAssertTrue(message.contains("Ubuntu 24.04 device"))
    }

    /// Issue #322: `remoteDevelopmentProfileName`'s `providedProfile ?? SpacesProfile.current()` fallback
    /// used to discard a test-host refusal with `try?`, so a caller that passed no profile (or a test
    /// exercising this function directly, as here) would silently get `nil` — indistinguishable from
    /// "this account genuinely has no development profile" — and fall through to `installedRemotePairCommand`,
    /// the installed-profile command. `remotePairCommand`/`remoteDevelopmentProfileName` already `throw`
    /// end to end, so nothing but the fix itself stands between the refusal and the caller now.
    func testRemotePairCommandRethrowsTestHostRefusalInsteadOfDegradingToInstalledDefault() throws {
        let accountHomePath = try XCTUnwrap(SpacesProfile.accountHomeDirectoryPath())

        try withProfileEnvironmentOverride(home: accountHomePath) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            XCTAssertThrowsError(try SpacesDevicePairingClient.remotePairCommand(profile: nil)) { error in
                guard case SpacesProfileResolutionError.testHostRefusedLiveUserProfile = error else {
                    return XCTFail("Expected testHostRefusedLiveUserProfile, got \(error).")
                }
            }
        }
    }

    /// Issue #322 follow-up: `localMacClientInstallationID`'s `profile ?? SpacesProfile.current()` fallback
    /// used to discard a test-host refusal with `try?` and land on the same `NSHomeDirectory()` fallback
    /// as an ordinary "no profile" outcome, with nothing to tell the two apart. It cannot become `throws`
    /// (it backs a default parameter value on `SpacesDeviceClient.macOSClientApp`, itself defaulted across
    /// dozens of call sites — Swift rejects a throwing default argument outright) and, called from that
    /// default position on essentially every Device API request across the whole app, it is far too widely
    /// shared to trap on either; see `SpacesProfile.currentOrNilLoggingRefusal`'s doc comment. This proves
    /// the wiring survives a refusal end to end: a refused resolution still lands on the documented
    /// fallback — the same id a profile explicitly rooted at `NSHomeDirectory()` would produce — rather
    /// than crashing or producing something else.
    func testLocalMacClientInstallationIDFallsBackToHomeDirectoryIDWhenProfileResolutionIsRefused() throws {
        let accountHomePath = try XCTUnwrap(SpacesProfile.accountHomeDirectoryPath())
        let homeDirectory = NSHomeDirectory()
        let fallbackProfile = SpacesProfile(
            source: .installedFallback, databasePath: "\(homeDirectory)/.spaces/spaces.db", rootDirectory: homeDirectory, isInstalledProfile: false,
            runtimeDirectory: "\(homeDirectory)/.spaces/runtime", ipcNotificationObject: "unused-in-this-test", developmentContext: nil,
            branchSlug: nil, worktreeHash: nil)
        let expectedFallbackID = SpacesDevicePairingClient.localMacClientInstallationID(profile: fallbackProfile)

        try withProfileEnvironmentOverride(home: accountHomePath) {
            SpacesProfile.resetCacheForTesting()
            defer { SpacesProfile.resetCacheForTesting() }

            XCTAssertEqual(SpacesDevicePairingClient.localMacClientInstallationID(), expectedFallbackID)
        }
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
                exitStatus: 0, standardError: "", standardOutput: #"{"name":"Lost & not found Mac","host":"studio.local","port":8443}"#))
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

    func testRemoteSpacesNotInstalledGuidesMacUserToInstallAppWithoutCommand() throws {
        let probe = RemoteInstallProbe(operatingSystem: "Darwin", architecture: "arm64", linuxID: nil, linuxVersionID: nil)
        let error = SpacesDevicePairingClient.remoteSpacesNotInstalledError(
            lead: "SSH connected to studio-mac, but Spaces is not installed for that user.", probe: probe, appVersion: "0.1.0")

        guard case .remoteSpacesNotInstalled(_, let command) = error else { return XCTFail("expected remoteSpacesNotInstalled") }
        XCTAssertNil(command)  // Mac users install the app; no shell one-liner travels with the error.
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("studio-mac"))
        XCTAssertTrue(message.contains("Install the Spaces app on the remote Mac"))
        XCTAssertTrue(message.contains("open it once"))
        XCTAssertFalse(message.contains("install.sh"))
    }

    func testRemoteSpacesNotInstalledGivesLinuxUserVersionPinnedInstaller() throws {
        let probe = RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04")
        let error = SpacesDevicePairingClient.remoteSpacesNotInstalledError(
            lead: "SSH connected to builder.local, but Spaces is not installed for that user.", probe: probe, appVersion: "0.1.0")

        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("builder.local"))
        XCTAssertTrue(message.contains("Ubuntu 24.04 device"))
        XCTAssertTrue(message.contains("curl -fsSL https://usespaces.dev/install.sh | bash -s -- 0.1.0"))
    }

    func testRemoteSpacesNotInstalledUsesEvergreenInstallerWhenAppVersionMissing() throws {
        let probe = RemoteInstallProbe(operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04")
        let error = SpacesDevicePairingClient.remoteSpacesNotInstalledError(
            lead: "SSH connected to builder.local, but Spaces is not installed for that user.", probe: probe, appVersion: nil)

        let message = try XCTUnwrap(error.errorDescription)
        // A missing app version yields the evergreen (latest-release) command, never a "latest" literal.
        XCTAssertTrue(message.contains("curl -fsSL https://usespaces.dev/install.sh | bash"))
        XCTAssertFalse(message.contains("-s --"))
        XCTAssertFalse(message.lowercased().contains("latest"))
    }

    func testRemoteSpacesNotInstalledErrorDescriptionAppendsCommandWhenPresent() {
        let withCommand = SpacesRemoteDevicePairingError.remoteSpacesNotInstalled(
            message: "Install or update Spaces on the Ubuntu 24.04 device, then pair again.",
            linuxInstallCommand: "curl -fsSL https://usespaces.dev/install.sh | bash")
        XCTAssertEqual(
            withCommand.errorDescription,
            "Install or update Spaces on the Ubuntu 24.04 device, then pair again.\n  curl -fsSL https://usespaces.dev/install.sh | bash")

        let withoutCommand = SpacesRemoteDevicePairingError.remoteSpacesNotInstalled(
            message: "Install the Spaces app on the remote Mac, open it once, then pair again.", linuxInstallCommand: nil)
        XCTAssertEqual(withoutCommand.errorDescription, "Install the Spaces app on the remote Mac, open it once, then pair again.")
    }

    func testRemoteInstallTimedOutErrorDescriptionMentionsTenMinutes() {
        let error = SpacesRemoteDevicePairingError.remoteInstallTimedOut("dev@builder.local")
        XCTAssertEqual(
            error.errorDescription, "Installing Spaces on dev@builder.local timed out after 10 minutes. Check the device's network and try again.")
    }

    func testRemoteInstallFailedErrorSurfacesScriptDieVerbatim() {
        let message = SpacesDevicePairingClient.remoteInstallFailureMessage(
            destination: "builder.local", standardOutput: "downloading...",
            standardError: "spaces-install-linux.sh: the Spaces daemon supports Ubuntu 24.04 (detected debian 12).", exitStatus: 1)
        XCTAssertEqual(SpacesRemoteDevicePairingError.remoteInstallFailed(message).errorDescription, message)
        XCTAssertTrue(message.contains("builder.local"))
        XCTAssertTrue(message.contains("supports Ubuntu 24.04 (detected debian 12)"))
    }

    func testRemoteInstallFailureMessageKeepsOnlyLastLines() {
        let lines = (1...20).map { "line\($0)" }.joined(separator: "\n")
        let message = SpacesDevicePairingClient.remoteInstallFailureMessage(
            destination: "builder.local", standardOutput: lines, standardError: "", exitStatus: 2)
        XCTAssertTrue(message.contains("line20"))
        XCTAssertTrue(message.contains("line11"))
        XCTAssertFalse(message.contains("line10"))
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
        let restartRange = try XCTUnwrap(script.range(of: #"systemctl --user restart "$service_unit""#))
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
        // Every systemd action is scoped to the unit the selected target owns, so installing one profile
        // never restarts another profile's daemon.
        XCTAssertTrue(script.contains(#"systemctl --user restart "$service_unit""#))
        XCTAssertTrue(script.contains(#"systemctl --user enable "$service_unit""#))
        XCTAssertFalse(script.contains("systemctl --user restart spacesd.service"))
    }

    /// A development profile is installed as an instance of one shared template unit whose `ExecStart` is
    /// resolved from the instance name alone. The template carries no per-profile content — no `Environment=`
    /// assignment of a database, runtime root, host, or port — because a profile-rooted binary resolves all
    /// of that from where it lives; baking a profile into the unit is what previously pinned a device's one
    /// daemon to one developer's worktree.
    func testLinuxArtifactInstallerInstallsOneTemplateUnitPerDevelopmentProfile() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_linux_spacesd_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains(#"profile_root="$HOME/.spaces-dev/profiles/spaces/$profile_name""#))
        XCTAssertTrue(script.contains(#"service_unit="spacesd@$profile_name.service""#))
        XCTAssertTrue(script.contains(#"service_path="$service_dir/spacesd@.service""#))
        XCTAssertTrue(script.contains("ExecStart=%h/.spaces-dev/profiles/spaces/%i/daemon/current/bin/spacesd"))
        for bakedInEnvironment in [
            "Environment=SPACES_DB_PATH", "Environment=SPACES_RUNTIME_DIR", "Environment=SPACES_DEVICE_API_HOST",
            "Environment=SPACES_DEVICE_API_PORT",
        ] { XCTAssertFalse(script.contains(bakedInEnvironment), "A unit must not bake \(bakedInEnvironment) into a profile's daemon.") }
        // The performance log is the one per-instance setting, and it arrives as a drop-in for that instance
        // rather than as content in the shared template.
        XCTAssertTrue(script.contains(#"performance_log_drop_in_dir="$service_dir/$service_unit.d""#))
        XCTAssertTrue(script.contains("Environment=SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH=$performance_log_path"))
        XCTAssertTrue(script.contains(#"rm -f "$performance_log_drop_in_path""#))
    }

    /// The installer's target is chosen by its own argument and by nothing else. Reading the installing
    /// shell's `SPACES_*` variables is what let one worktree's profile become this device's single shared
    /// daemon, so the installed layout must not depend on them at all.
    func testLinuxArtifactInstallerIgnoresAmbientProfileEnvironment() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_linux_spacesd_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("Usage: install.sh [--profile NAME] [--performance-log PATH]"))
        for ambientDefault in [
            #"db_path="${SPACES_DB_PATH:-"#, #"runtime_dir="${SPACES_RUNTIME_DIR:-"#, #"device_api_host="${SPACES_DEVICE_API_HOST:-"#,
            #"device_api_port="${SPACES_DEVICE_API_PORT:-"#, #"performance_log_path="${SPACES_MOBILE_TERMINAL_PERFORMANCE_LOG_PATH:-"#,
        ] { XCTAssertFalse(script.contains(ambientDefault), "install.sh must not take its layout from the installing shell (\(ambientDefault)).") }
    }

    func testLinuxArtifactInstallerVerifiesHandoffAndRestartCompletion() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build_linux_spacesd_artifact.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains(#"staged_daemon_identity="$(stat -Lc '%d:%i' "$release_dir/bin/spacesd-bin")""#))
        XCTAssertTrue(script.contains("/proc/$daemon_pid/exe"))
        XCTAssertTrue(script.contains("wait_for_staged_daemon \"$handoff_pid\""))
        XCTAssertTrue(script.contains("spacesd is running the installed daemon image and is still resuming sessions"))
        XCTAssertTrue(script.contains("leaving the running daemon and its sessions untouched"))
        XCTAssertTrue(script.contains("accepted the staged handoff but did not exec the installed image within 10s; leaving it running"))
        XCTAssertFalse(script.contains("spacesd did not complete the staged handoff; restarting it with systemd"))
        XCTAssertTrue(script.contains("spacesd did not start the installed daemon image within 10s"))
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

    /// The demo's remote daemon is a development profile of its own, never the remote account's installed
    /// profile: a source build carries no release version, and the installed lane is the one real paired
    /// clients talk to. So the artifact is installed with that profile's name and, crucially, with no
    /// environment prefix at all — a profile-rooted binary resolves its database, runtime root, and Device
    /// API port from where it lives. Pinning the whole install command, the port lookup, and the CLI the
    /// pairing window is opened through is what keeps a stray environment assignment, or a slip back to the
    /// installed lane, from silently redirecting the daemon the demo then pairs with.
    func testMobileDemoInstallsRemoteDevelopmentProfileBeforePairing() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "run_mobile_terminal_demo.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let prepareRange = try XCTUnwrap(script.range(of: "  prepare_remote_demo_daemon"))
        let pairRange = try XCTUnwrap(script.range(of: #""$spaces_cli" device pair --link "$remote_pairing_link""#))
        XCTAssertLessThan(prepareRange.lowerBound, pairRange.lowerBound)
        XCTAssertTrue(script.contains(#"remote_demo_profile_name="remote-mobile-demo""#))
        XCTAssertTrue(script.contains(#"deploy_linux_spacesd_e2e.sh" --profile "$remote_demo_profile_name""#))

        let installLine = try XCTUnwrap(
            script.split(separator: "\n").first { $0.contains("$quoted_install/install.sh") }, "The demo must install the deployed artifact.")
        XCTAssertEqual(
            installLine.trimmingCharacters(in: .whitespaces),
            #"remote_ssh "rm -rf $quoted_install && mkdir -p $quoted_install && tar -xzf $quoted_archive -C $quoted_install --strip-components=1 && $quoted_install/install.sh --profile $quoted_profile_name" >/dev/null"#
        )
        // The port is the one the daemon assigned itself for this profile and persisted, read back from that
        // profile's own Device API settings. Nothing in the lane chooses a port.
        XCTAssertTrue(script.contains(#"$remote_demo_profile_root/runtime/terminal/device-api.json"#))
        XCTAssertFalse(script.contains("remote_demo_daemon_port=47847"))
        XCTAssertFalse(script.contains("SPACES_E2E_REMOTE_DAEMON_PORT"))
        XCTAssertTrue(script.contains("remote demo daemon port {port} did not open"))
        // Pairing windows are opened through the deployed profile's own CLI, so the installed profile's
        // binaries are never reached.
        XCTAssertTrue(script.contains(#"remote_demo_cli="$remote_demo_profile_root/daemon/current/bin/spaces""#))
        XCTAssertFalse(script.contains("~/.spaces/bin/spaces"))
    }

    /// Every lane that redeems a pairing link redeems the daemon's own, with nothing but its endpoint moved
    /// to an address the running machine can reach.
    ///
    /// A harness that reassembled the link would pin a copy of a format it does not own — the link version,
    /// the daemon's wire-protocol version, and its app version are the daemon's to state — and pairing would
    /// fail outright the next time that format moves, which is exactly how a hand-built link went stale
    /// before. The substitution rewrites only the endpoint parameters and passes every other one through as
    /// written, so the escapes the daemon chose survive to the client that reads them back.
    func testRemoteLanesRedeemDaemonPairingLinkVerbatim() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for lane in ["run_mobile_terminal_demo.sh", "e2e_remote_terminal_send.sh"] {
            let script = try String(contentsOf: testsRoot.appendingPathComponent(lane), encoding: .utf8)
            XCTAssertTrue(script.contains("pairingLink"), lane)
            XCTAssertTrue(script.contains("rewrite_pairing_link_endpoint"), lane)
            XCTAssertFalse(script.contains("spaces://pair"), lane)
        }

        let helper = try String(contentsOf: testsRoot.appendingPathComponent("pairing_link_endpoint.sh"), encoding: .utf8)
        XCTAssertTrue(helper.contains(#"substituted.append("host=" + quote(host, safe=""))"#))
        XCTAssertTrue(helper.contains(#"substituted.append("port=" + quote(port, safe=""))"#))
        XCTAssertTrue(helper.contains("substituted.append(parameter)"))
        XCTAssertFalse(helper.contains("urlencode"))

        // A lane that dials a daemon's Device API directly addresses it by the SSH destination's effective
        // HostName, which only ssh can report: a configured host may be an ssh_config alias, and a link
        // carrying the alias fails DNS the moment the client redeems it.
        XCTAssertTrue(helper.contains(#"ssh -G -T "$@" "$destination""#))
        XCTAssertTrue(helper.contains(#"tolower($1) == "hostname""#))
        let directLane = try String(contentsOf: testsRoot.appendingPathComponent("e2e_remote_terminal_send.sh"), encoding: .utf8)
        XCTAssertTrue(directLane.contains(#"REMOTE_DAEMON_HOST="$(resolve_ssh_hostname "$(remote_destination)" "${ssh_option_args[@]}")""#))
    }

    /// The mobile demo reaches its remote daemon through the SSH forward and nothing else: the forward is
    /// established before anything pairs, and the endpoint every client is handed — this Mac's CLI, the
    /// paired-device record it writes, the simulator seeds, and every pairing link — is the forward's
    /// loopback address.
    ///
    /// The lane has to work from a network where the remote's Device API port is unreachable and SSH is the
    /// only route in, so a step that dialed that port directly would quietly narrow the supported envelope
    /// to whatever the remote's firewall happens to open. Pairing through the forward is equivalent because
    /// pinned TLS authenticates the daemon by the certificate fingerprint the link carries, never by
    /// hostname.
    func testMobileDemoReachesRemoteDaemonOnlyThroughSSHForward() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "run_mobile_terminal_demo.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let prepareRange = try XCTUnwrap(script.range(of: "  prepare_remote_demo_daemon"))
        let forwardRange = try XCTUnwrap(script.range(of: "  start_remote_device_forward"))
        let pairRange = try XCTUnwrap(script.range(of: #""$spaces_cli" device pair --link "$remote_pairing_link""#))
        XCTAssertLessThan(prepareRange.lowerBound, forwardRange.lowerBound)
        XCTAssertLessThan(forwardRange.lowerBound, pairRange.lowerBound)

        // The tunnel's remote side is the port the profile assigned itself, and its local side is the only
        // endpoint the lane ever hands a client.
        XCTAssertTrue(script.contains(#"-L "$remote_forward_host:$remote_forward_port:127.0.0.1:$remote_demo_daemon_port""#))
        XCTAssertTrue(script.contains(#"remote_device_host="$remote_forward_host""#))
        XCTAssertTrue(script.contains(#"remote_device_port="$remote_forward_port""#))
        XCTAssertTrue(script.contains(#"rewrite_pairing_link_endpoint "$remote_pairing_link" "$remote_device_host" "$remote_device_port""#))
        XCTAssertFalse(script.contains(#"remote_device_host="$remote_ssh_host""#))
    }

    /// The remote development daemon a repo-local build deploys is the same profile this Mac's pairing
    /// derives: named after the local profile, installed with the profile name alone, and verified through
    /// its own unit instance and its own CLI. No database, runtime, host, or port environment reaches the
    /// installer — a profile-rooted binary resolves all of that from where it lives — so a leftover
    /// environment assignment here would silently recreate the coupling that pinned one shared daemon to
    /// one developer's profile.
    func testDevBuildLaunchDeploysRemoteProfileWithoutEnvironmentCoupling() throws {
        let scriptURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/dev-build-and-launch.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        // The profile name comes from the root the local binaries themselves resolved, looked up through
        // `profile-show`, rather than from a SPACES_DB_PATH the shell was bound to: nothing exports one, and
        // resolution refuses a live profile root named that way.
        XCTAssertTrue(script.contains(#"remote_profile_name="$(basename "${PROFILE_ROOT:?}")""#))
        XCTAssertTrue(script.contains(#"PROFILE_ROOT="$(spaces_profile_field "$CLI" profileRoot)""#))
        XCTAssertTrue(script.contains(#"remote_profile_root="$(remote_expand_path "~/.spaces-dev/profiles/spaces/$remote_profile_name")""#))
        XCTAssertTrue(script.contains("$quoted_install/install.sh --profile $quoted_profile_name"))
        XCTAssertTrue(script.contains(#"systemctl --user is-active --quiet "spacesd@$profile_name.service""#))
        XCTAssertTrue(script.contains(#""$profile_root/daemon/current/bin/spaces" terminal list"#))
        XCTAssertFalse(script.contains("SPACES_DB_PATH=$quoted_remote_db_path"))
        XCTAssertFalse(script.contains("SPACES_DEVICE_API_PORT=$remote_daemon_port"))
        XCTAssertFalse(script.contains("~/.local/bin/spaces mobile status"))
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

    /// Points `HOME` at the real account home and clears both profile overrides, the shape an unisolated
    /// test process is left in — the case `SpacesProfile` refuses to resolve for a test host. Restores all three afterward; this test class runs its methods
    /// serially in one XCTest process, so the temporary global mutation cannot race a sibling test here.
    private func withProfileEnvironmentOverride(home: String, run: () throws -> Void) throws {
        let names = ["HOME", SpacesProfile.databasePathEnvironmentVariable, SpacesProfile.runtimeDirectoryEnvironmentVariable]
        let originals = names.map { ($0, getenv($0).map { String(cString: $0) }) }
        setenv("HOME", home, 1)
        unsetenv(SpacesProfile.databasePathEnvironmentVariable)
        unsetenv(SpacesProfile.runtimeDirectoryEnvironmentVariable)
        defer { for (name, value) in originals { if let value { setenv(name, value, 1) } else { unsetenv(name) } } }
        try run()
    }
}
