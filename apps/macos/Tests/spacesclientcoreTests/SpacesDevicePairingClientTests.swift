import XCTest

@testable import spacesclientcore

#if canImport(CryptoKit)
    import CryptoKit
#endif

final class SpacesDevicePairingClientTests: XCTestCase {
    func testRemoteInstallPreflightAllowsLinuxWithoutDMGMarkers() throws {
        let probe = RemoteInstallProbe(
            operatingSystem: "Linux", architecture: "x86_64", linuxID: "ubuntu", linuxVersionID: "24.04", spacesAppInstalled: false,
            systemCLIExecutable: false, systemDaemonExecutable: false, canonicalCLIExecutable: false, launchAgentInstalled: false)

        XCTAssertNoThrow(try SpacesDevicePairingClient.validateRemoteInstallProbe(probe, destination: "builder.local"))
    }

    func testRemoteInstallPreflightAllowsDarwinDMGInstall() throws {
        let probe = RemoteInstallProbe(
            operatingSystem: "Darwin", architecture: "arm64", linuxID: nil, linuxVersionID: nil, spacesAppInstalled: true, systemCLIExecutable: true,
            systemDaemonExecutable: true, canonicalCLIExecutable: true, launchAgentInstalled: true)

        XCTAssertNoThrow(try SpacesDevicePairingClient.validateRemoteInstallProbe(probe, destination: "studio.local"))
    }

    func testRemoteInstallPreflightRequiresDMGForDarwin() throws {
        let probe = RemoteInstallProbe(
            operatingSystem: "Darwin", architecture: "arm64", linuxID: nil, linuxVersionID: nil, spacesAppInstalled: false, systemCLIExecutable: true,
            systemDaemonExecutable: true, canonicalCLIExecutable: false, launchAgentInstalled: false)

        XCTAssertThrowsError(try SpacesDevicePairingClient.validateRemoteInstallProbe(probe, destination: "studio.local")) { error in
            guard case .remoteMacDMGInstallRequired(let message) = error as? SpacesRemoteDevicePairingError else {
                XCTFail("Expected remoteMacDMGInstallRequired, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Spaces is not fully installed"))
            XCTAssertTrue(message.contains("Install the Spaces app on the remote Mac"))
            XCTAssertTrue(message.contains("open it once if needed"))
            XCTAssertFalse(message.contains("spacesd"))
        }
    }

    func testRemoteInstallProbeParsesDarwinMarkers() throws {
        let probe = try SpacesDevicePairingClient.parseRemoteInstallProbeOutput(
            """
            os=Darwin
            arch=arm64
            spaces_app=1
            usr_local_spaces=1
            usr_local_spacesd=1
            home_spaces_cli=1
            launch_agent=1
            """, destination: "studio.local")

        XCTAssertEqual(
            probe,
            RemoteInstallProbe(
                operatingSystem: "Darwin", architecture: "arm64", linuxID: nil, linuxVersionID: nil, spacesAppInstalled: true,
                systemCLIExecutable: true, systemDaemonExecutable: true, canonicalCLIExecutable: true, launchAgentInstalled: true))
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
            probe,
            RemoteInstallProbe(
                operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04", spacesAppInstalled: false,
                systemCLIExecutable: false, systemDaemonExecutable: false, canonicalCLIExecutable: false, launchAgentInstalled: false))
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

    func testSelectRemoteLinuxArtifactMatchesSupportedPlatform() throws {
        let manifest = RemoteArtifactManifest(
            schemaVersion: 1, appVersion: "1.2.3", releaseTag: "v1.2.3",
            artifacts: [
                RemoteLinuxArtifact(
                    id: "spacesd-ubuntu-24.04-x86_64", version: "1.2.3", platform: "ubuntu-24.04", architecture: "x86_64",
                    archiveName: "spacesd-ubuntu-24.04-x86_64.tar.gz",
                    url: "https://github.com/yogesh-dhande/spaces/releases/download/v1.2.3/spacesd-ubuntu-24.04-x86_64.tar.gz",
                    sha256: String(repeating: "a", count: 64)),
                RemoteLinuxArtifact(
                    id: "spacesd-ubuntu-24.04-arm64", version: "1.2.3", platform: "ubuntu-24.04", architecture: "arm64",
                    archiveName: "spacesd-ubuntu-24.04-arm64.tar.gz",
                    url: "https://github.com/yogesh-dhande/spaces/releases/download/v1.2.3/spacesd-ubuntu-24.04-arm64.tar.gz",
                    sha256: String(repeating: "b", count: 64)),
            ])
        let probe = RemoteInstallProbe(
            operatingSystem: "Linux", architecture: "aarch64", linuxID: "ubuntu", linuxVersionID: "24.04", spacesAppInstalled: false,
            systemCLIExecutable: false, systemDaemonExecutable: false, canonicalCLIExecutable: false, launchAgentInstalled: false)

        let artifact = try SpacesDevicePairingClient.selectRemoteLinuxArtifact(
            from: manifest, probe: probe, appVersion: "1.2.3", destination: "builder.local")

        XCTAssertEqual(artifact.id, "spacesd-ubuntu-24.04-arm64")
    }

    func testSelectRemoteLinuxArtifactRejectsUnsupportedLinux() throws {
        let manifest = RemoteArtifactManifest(schemaVersion: 1, appVersion: "1.2.3", releaseTag: "v1.2.3", artifacts: [])
        let probe = RemoteInstallProbe(
            operatingSystem: "Linux", architecture: "x86_64", linuxID: "debian", linuxVersionID: "12", spacesAppInstalled: false,
            systemCLIExecutable: false, systemDaemonExecutable: false, canonicalCLIExecutable: false, launchAgentInstalled: false)

        XCTAssertThrowsError(
            try SpacesDevicePairingClient.selectRemoteLinuxArtifact(from: manifest, probe: probe, appVersion: "1.2.3", destination: "builder.local")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("Ubuntu 24.04")) }
    }

    func testRemotePairCommandMissingShowsUserFacingSetupInstruction() {
        let message = SpacesDevicePairingClient.remotePairCommandFailureMessage(
            destination: "builder.local", standardError: "sh: 1: ~/.spaces/bin/spaces: not found", standardOutput: "", exitStatus: 127)

        XCTAssertTrue(message.contains("Spaces is not available for that user"))
        XCTAssertTrue(message.contains("install the Spaces app"))
        XCTAssertTrue(message.contains("automatic setup"))
        XCTAssertFalse(message.contains("spacesd"))
    }

    func testRemoteShellCommandRunsSnippetsThroughPOSIXShell() {
        let wrapped = SpacesDevicePairingClient.remoteShellCommand("printf 'ok'\nuname -s")

        XCTAssertTrue(wrapped.hasPrefix("sh -c '"))
        XCTAssertTrue(wrapped.hasSuffix("'"))
        XCTAssertFalse(wrapped.hasPrefix("sh -lc "))
        XCTAssertTrue(wrapped.contains("printf '\\''ok'\\''"))
        XCTAssertTrue(wrapped.contains("\nuname -s"))
    }

    func testCurlDownloadArgumentsSuppressProgressButShowErrors() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/spaces.tar.gz"))
        let destination = URL(fileURLWithPath: "/tmp/spaces.tar.gz")

        let arguments = SpacesDevicePairingClient.curlDownloadArguments(url: url, destination: destination, timeoutSeconds: 300)

        XCTAssertTrue(arguments.contains("-f"))
        XCTAssertTrue(arguments.contains("-sS"))
        XCTAssertTrue(arguments.contains("-L"))
        XCTAssertEqual(Array(arguments.suffix(2)), [destination.path, url.absoluteString])
    }

    func testSCPRemoteDestinationBracketsIPv6Literals() {
        XCTAssertEqual(
            SpacesDevicePairingClient.scpRemoteDestination(destination: "dev@2001:db8::1", remotePath: "/tmp/spaces.tar.gz"),
            "dev@[2001:db8::1]:/tmp/spaces.tar.gz")
        XCTAssertEqual(
            SpacesDevicePairingClient.scpRemoteDestination(destination: "2001:db8::1", remotePath: "/tmp/spaces.tar.gz"),
            "[2001:db8::1]:/tmp/spaces.tar.gz")
        XCTAssertEqual(
            SpacesDevicePairingClient.scpRemoteDestination(destination: "dev@[2001:db8::1]", remotePath: "/tmp/spaces.tar.gz"),
            "dev@[2001:db8::1]:/tmp/spaces.tar.gz")
        XCTAssertEqual(
            SpacesDevicePairingClient.scpRemoteDestination(destination: "dev@builder.local", remotePath: "/tmp/spaces.tar.gz"),
            "dev@builder.local:/tmp/spaces.tar.gz")
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

    #if canImport(CryptoKit)
        func testRemoteArtifactManifestSignatureVerificationUsesPinnedKey() throws {
            let key = Curve25519.Signing.PrivateKey()
            let manifestData = Data(#"{"schema_version":1}"#.utf8)
            let signature = try key.signature(for: manifestData)
            let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

            XCTAssertNoThrow(
                try SpacesDevicePairingClient.verifyRemoteArtifactManifestSignature(
                    manifestData: manifestData, signature: signature, publicKey: publicKey))

            XCTAssertThrowsError(
                try SpacesDevicePairingClient.verifyRemoteArtifactManifestSignature(
                    manifestData: Data(#"{"schema_version":2}"#.utf8), signature: signature, publicKey: publicKey))
        }
    #endif

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
