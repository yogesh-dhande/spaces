import Foundation
import XCTest

@testable import spacesterminalcore

#if os(macOS)
    import Darwin

    final class TerminalServiceTests: XCTestCase {
        // Regression: capturing output used to wait for exit before draining the pipe, which
        // deadlocks as soon as the child writes more than the kernel's 64KB pipe buffer
        // (observed live with `lsof -nP -U` during socket-owner lookups).
        func testCapturedStandardOutputDrainsOutputLargerThanThePipeBuffer() throws {
            let result = try XCTUnwrap(
                TerminalService.capturedStandardOutput(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' 'x'"], timeout: 30))

            XCTAssertEqual(result.terminationStatus, 0)
            XCTAssertEqual(result.output.count, 256 * 1024)
        }

        // Regression: the lsof sweep behind serviceProcessIDsOwningSocket had no deadline, so a
        // loaded machine could block CaddyService.stop()'s bounded shutdown indefinitely.
        func testCapturedStandardOutputReturnsNilPromptlyWhenChildOutlivesTimeout() throws {
            let startedAt = Date()

            let result = TerminalService.capturedStandardOutput(
                executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 60"], timeout: 1)

            XCTAssertNil(result)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)
        }

        func testResolveExecutableURLFindsServiceNextToInstalledCLI() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let cli = root.appendingPathComponent("spaces", isDirectory: false)
            let service = root.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: cli)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": cli.path], profile: makeProfile(isInstalled: true, source: .installedFallback))

            XCTAssertEqual(resolved.path, service.path)
        }

        func testResolveExecutableURLFindsServiceInAppBundleResources() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let macOS = root.appendingPathComponent("Spaces.app/Contents/MacOS", isDirectory: true)
            let resources = root.appendingPathComponent("Spaces.app/Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let appExecutable = macOS.appendingPathComponent("SpacesApp", isDirectory: false)
            let service = resources.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: appExecutable)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": appExecutable.path], profile: makeProfile(isInstalled: true, source: .installedFallback))

            XCTAssertEqual(resolved.path, service.path)
        }

        func testResolveExecutableURLFindsServiceBesideBundledCLIResource() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Spaces.app/Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let cli = resources.appendingPathComponent("spaces", isDirectory: false)
            let service = resources.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: cli)
            try makeExecutableFile(at: service)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": cli.path], profile: makeProfile(isInstalled: true, source: .installedFallback))

            XCTAssertEqual(resolved.path, service.path)
        }

        func testResolveExecutableURLFindsServiceThroughHomeHelperSymlink() throws {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Applications/Spaces.app/Contents/Resources", isDirectory: true)
            let helperBin = root.appendingPathComponent("Users/test/.spaces/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: helperBin, withIntermediateDirectories: true)
            let cliTarget = resources.appendingPathComponent("spaces", isDirectory: false)
            let serviceTarget = resources.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: cliTarget)
            try makeExecutableFile(at: serviceTarget)
            let cliHelper = helperBin.appendingPathComponent("spaces", isDirectory: false)
            let serviceHelper = helperBin.appendingPathComponent("spacesd", isDirectory: false)
            try FileManager.default.createSymbolicLink(at: cliHelper, withDestinationURL: cliTarget)
            try FileManager.default.createSymbolicLink(at: serviceHelper, withDestinationURL: serviceTarget)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": cliHelper.path], profile: makeProfile(isInstalled: true, source: .installedFallback))

            XCTAssertEqual(resolved.path, serviceHelper.path)
        }

        // The installed profile is the only one the location-fixed installed links may serve, and it
        // still reaches them when nothing beside the running executable matches.
        func testResolveExecutableURLUsesInstalledLinkForInstalledProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager,
                profile: makeProfile(isInstalled: true, source: .installedFallback), installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, layout.installedDaemon.path)
        }

        // Regression: a repo-local profile whose own `.build/debug/spacesd` was not executable fell
        // through to `~/.spaces/bin/spacesd` and started the installed release against the development
        // profile's runtime directory and socket. That daemon answered on an older wire protocol, so the
        // sidebar reload failed with `daemonWireIncompatible` and the real cause — the wrong binary
        // entirely — was invisible. A development profile must fail instead of borrowing another build.
        func testResolveExecutableURLRefusesInstalledLinkForDevelopmentProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let profile = makeProfile(isInstalled: false, source: .developmentWorktree)

            XCTAssertThrowsError(
                try TerminalService.resolveExecutableURL(
                    environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager, profile: profile,
                    installedLinkURLs: [layout.installedDaemon])
            ) { error in
                guard case TerminalServiceError.daemonNotFound(let reportedProfile, let searchedPaths) = error else {
                    return XCTFail("Expected daemonNotFound, got \(error)")
                }
                XCTAssertEqual(reportedProfile.source, .developmentWorktree)
                XCTAssertEqual(reportedProfile.rootDirectory, profile.rootDirectory)
                XCTAssertFalse(searchedPaths.contains(layout.installedDaemon.path))
                let message = (error as? TerminalServiceError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains(profile.rootDirectory))
                XCTAssertTrue(message.contains("never starts the installed daemon"))
            }
        }

        // An explicit SPACES_DB_PATH names a data location that is not the installed profile's, so it is
        // governed by the same rule as a worktree profile.
        func testResolveExecutableURLRefusesInstalledLinkForExplicitDatabaseProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }

            XCTAssertThrowsError(
                try TerminalService.resolveExecutableURL(
                    environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager,
                    profile: makeProfile(isInstalled: false, source: .explicitDatabasePath), installedLinkURLs: [layout.installedDaemon])
            ) { error in
                guard case TerminalServiceError.daemonNotFound(let reportedProfile, _) = error else {
                    return XCTFail("Expected daemonNotFound, got \(error)")
                }
                XCTAssertEqual(reportedProfile.source, .explicitDatabasePath)
            }
        }

        // A development profile is the only one the checkout-relative candidates may serve, and it still
        // reaches them when nothing beside the running executable matches.
        func testResolveExecutableURLUsesCheckoutRelativeDaemonForDevelopmentProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let checkoutDaemon = try makeCheckoutRelativeDaemon(in: layout)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager,
                profile: makeProfile(isInstalled: false, source: .developmentWorktree), installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, checkoutDaemon.path)
        }

        // The mirror of the installed-link rule: the checkout-relative candidates describe whichever
        // checkout the process happened to be started in, which says nothing about the installed profile.
        // An installed profile launched from inside a checkout must not be served by that checkout's
        // development build — the same invisible cross-build failure, in the opposite direction.
        func testResolveExecutableURLRefusesCheckoutRelativeDaemonForInstalledProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let checkoutDaemon = try makeCheckoutRelativeDaemon(in: layout)
            let absentInstalledLink = layout.root.appendingPathComponent("absent-installed-spacesd", isDirectory: false)
            let profile = makeProfile(isInstalled: true, source: .installedFallback)

            XCTAssertThrowsError(
                try TerminalService.resolveExecutableURL(
                    environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager, profile: profile,
                    installedLinkURLs: [absentInstalledLink])
            ) { error in
                guard case TerminalServiceError.daemonNotFound(let reportedProfile, let searchedPaths) = error else {
                    return XCTFail("Expected daemonNotFound, got \(error)")
                }
                XCTAssertEqual(reportedProfile.source, .installedFallback)
                XCTAssertEqual(reportedProfile.rootDirectory, profile.rootDirectory)
                XCTAssertFalse(searchedPaths.contains(checkoutDaemon.path))
                XCTAssertTrue(searchedPaths.contains(absentInstalledLink.path))
                let message = (error as? TerminalServiceError)?.errorDescription ?? ""
                XCTAssertTrue(message.contains(profile.rootDirectory))
                XCTAssertTrue(message.contains("never a development build from the current directory"))
            }
        }

        // A repo-built helper that bound itself to the installed profile (`spacese2e --installed-profile`)
        // does not belong to that profile's build, so its own sibling daemon is as foreign to it as a
        // checkout's build products are. Starting that sibling would put a development spacesd on
        // `~/.spaces`, where it would migrate the installed daemon's database out from under it.
        func testResolveExecutableURLRefusesTheAskingBuildsDaemonForABoundInstalledProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let siblingDaemon = layout.buildCLI.deletingLastPathComponent().appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: siblingDaemon)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager,
                profile: makeProfile(isInstalled: true, source: .explicitInstalledProfile), installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, layout.installedDaemon.path)
        }

        // `SPACESD_EXECUTABLE` is a redirection like any other, and a bound process does not act on the
        // redirections it inherited. Every terminal E2E lane exports it, so a QA sweep run from one of those
        // shells is the ordinary case rather than a contrived one: honouring it would start that checkout's
        // spacesd against `~/.spaces` and let it migrate the installed daemon's database.
        func testResolveExecutableURLIgnoresTheDaemonOverrideForABoundInstalledProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let overrideDaemon = layout.root.appendingPathComponent("override-spacesd", isDirectory: false)
            try makeExecutableFile(at: overrideDaemon)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path, SpacesProfile.daemonExecutableEnvironmentVariable: overrideDaemon.path],
                fileManager: layout.fileManager, profile: makeProfile(isInstalled: true, source: .explicitInstalledProfile),
                installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, layout.installedDaemon.path)
        }

        // With no installed daemon to serve it, a bound profile fails rather than falling back to ANY other
        // binary it can see — the daemon beside the running executable, or the one the environment pins — and
        // the searched paths show neither was ever a candidate.
        func testResolveExecutableURLFailsRatherThanBorrowingADaemonForABoundInstalledProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let siblingDaemon = layout.buildCLI.deletingLastPathComponent().appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: siblingDaemon)
            let overrideDaemon = layout.root.appendingPathComponent("override-spacesd", isDirectory: false)
            try makeExecutableFile(at: overrideDaemon)
            let absentInstalledLink = layout.root.appendingPathComponent("absent-installed-spacesd", isDirectory: false)

            XCTAssertThrowsError(
                try TerminalService.resolveExecutableURL(
                    environment: ["_": layout.buildCLI.path, SpacesProfile.daemonExecutableEnvironmentVariable: overrideDaemon.path],
                    fileManager: layout.fileManager, profile: makeProfile(isInstalled: true, source: .explicitInstalledProfile),
                    installedLinkURLs: [absentInstalledLink])
            ) { error in
                guard case TerminalServiceError.daemonNotFound(_, let searchedPaths) = error else {
                    return XCTFail("Expected daemonNotFound, got \(error)")
                }
                XCTAssertFalse(searchedPaths.contains(siblingDaemon.path))
                XCTAssertFalse(searchedPaths.contains(overrideDaemon.path))
                XCTAssertTrue(searchedPaths.contains(absentInstalledLink.path))
            }
        }

        // The daemon `ensureRunning` spawns has to resolve the SAME profile the spawn was decided for. A
        // bound installed profile is stated on this process's command line, which a child never sees, so an
        // inherited `SPACES_DB_PATH` or `SPACES_RUNTIME_DIR` would be the only thing reaching it — and the
        // daemon would come up on a scratch database, or with its socket and instance lock under another
        // profile's runtime root, while the parent waited on the installed profile's socket.
        func testDaemonSpawnEnvironmentDropsEveryRedirectingVariableForABoundInstalledProfile() {
            let profile = makeProfile(isInstalled: true, source: .explicitInstalledProfile)

            let environment = profile.environmentServingThisProfile([
                SpacesProfile.databasePathEnvironmentVariable: "/tmp/scratch/spaces.db",
                SpacesProfile.runtimeDirectoryEnvironmentVariable: "/tmp/scratch/runtime",
                SpacesProfile.daemonExecutableEnvironmentVariable: "/tmp/checkout/.build/debug/spacesd", "PATH": "/usr/bin",
            ])

            XCTAssertNil(environment[SpacesProfile.databasePathEnvironmentVariable])
            XCTAssertNil(environment[SpacesProfile.runtimeDirectoryEnvironmentVariable])
            XCTAssertNil(
                environment[SpacesProfile.daemonExecutableEnvironmentVariable],
                "A child that autostarts a daemon must not be handed the pin this process refused to honour.")
            XCTAssertEqual(environment["PATH"], "/usr/bin", "Only the redirecting variables are dropped; the rest of the environment is inherited.")
        }

        // The companion direction: every profile a process reached by belonging to it passes its environment
        // to the daemon untouched, including the ephemeral scratch root that only the override can describe
        // and the daemon the terminal E2E lanes pin. Dropping either there would leave the daemon serving a
        // different profile from its parent, or a different binary than the lane chose — the very failure the
        // bound case above exists to prevent, in reverse.
        func testDaemonSpawnEnvironmentForwardsRedirectingVariablesForAProfileTheBuildOwns() {
            for source: SpacesProfileSource in [.explicitDatabasePath, .developmentWorktree, .deployedDevelopmentProfile, .installedFallback] {
                let inherited = [
                    SpacesProfile.databasePathEnvironmentVariable: "/tmp/scratch/spaces.db",
                    SpacesProfile.runtimeDirectoryEnvironmentVariable: "/tmp/scratch/runtime",
                    SpacesProfile.daemonExecutableEnvironmentVariable: "/tmp/checkout/.build/debug/spacesd",
                ]

                let environment = makeProfile(isInstalled: source == .installedFallback, source: source).environmentServingThisProfile(inherited)

                XCTAssertEqual(environment, inherited, "A \(source.rawValue) profile's daemon inherits the environment that describes it.")
            }
        }

        func testResolveExecutableURLUsesDevelopmentBuildDaemonForDevelopmentProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let buildDaemon = layout.buildCLI.deletingLastPathComponent().appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: buildDaemon)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path], fileManager: layout.fileManager,
                profile: makeProfile(isInstalled: false, source: .developmentWorktree), installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, buildDaemon.path)
        }

        // SPACESD_EXECUTABLE names one binary outright, so it is a deliberate choice rather than a silent
        // substitution and keeps winning for every profile — the terminal E2E scripts pin their daemon with it.
        func testResolveExecutableURLHonorsExplicitOverrideForDevelopmentProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let overrideDaemon = layout.root.appendingPathComponent("override-spacesd", isDirectory: false)
            try makeExecutableFile(at: overrideDaemon)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path, "SPACESD_EXECUTABLE": overrideDaemon.path], fileManager: layout.fileManager,
                profile: makeProfile(isInstalled: false, source: .developmentWorktree), installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, overrideDaemon.path)
        }

        // The override outranks the installed links for the installed profile too, so an operator can
        // point the installed profile at a specific daemon without reinstalling. The profile here was
        // REACHED by the build that is asking (it fell through to `~/.spaces`), which is what separates this
        // from the bound case above — the same root, the opposite answer.
        func testResolveExecutableURLHonorsExplicitOverrideForInstalledProfile() throws {
            let layout = try makeDaemonResolutionLayout()
            defer { try? FileManager.default.removeItem(at: layout.root) }
            let overrideDaemon = layout.root.appendingPathComponent("override-spacesd", isDirectory: false)
            try makeExecutableFile(at: overrideDaemon)

            let resolved = try TerminalService.resolveExecutableURL(
                environment: ["_": layout.buildCLI.path, "SPACESD_EXECUTABLE": overrideDaemon.path], fileManager: layout.fileManager,
                profile: makeProfile(isInstalled: true, source: .installedFallback), installedLinkURLs: [layout.installedDaemon])

            XCTAssertEqual(resolved.path, overrideDaemon.path)
        }

        func testParseProcessIDsIgnoresWhitespaceAndInvalidLines() {
            XCTAssertEqual(TerminalService.parseProcessIDs("123\n\nnot-a-pid\n456 789\n"), [123, 456, 789])
        }

        func testParseSocketOwnerProcessIDsFiltersToMatchingSocketPath() {
            let socketPath = "/tmp/spaces-sockets-\(getuid())/service-current.sock"
            let output = """
                COMMAND     PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
                launchd       1 yogesh  12u  unix 0xffffffffffffffff      0t0      /tmp/spaces-sockets-\(getuid())/service-other.sock
                SpacesTer   222 yogesh  13u  unix 0xffffffffffffffff      0t0      \(socketPath)
                sleep       333 yogesh  14u  unix 0xffffffffffffffff      0t0      \(socketPath)
                broken      abc yogesh  15u  unix 0xffffffffffffffff      0t0      \(socketPath)
                """

            XCTAssertEqual(TerminalService.parseSocketOwnerProcessIDs(output, socketPath: socketPath), [222, 333])
        }

        func testDaemonWireCompatibleWhenVersionsMatch() {
            let response = TerminalServiceResponse(
                ok: true, message: "pong", daemonStatus: makeDaemonStatus(protocolVersion: SpacesWireProtocol.version))
            XCTAssertNil(TerminalService.daemonWireIncompatibilityDetails(response)?.message)
            XCTAssertNoThrow(try TerminalService.assertDaemonWireCompatible(response))
        }

        func testDaemonWireIncompatibleWhenDaemonIsOlder() throws {
            let response = TerminalServiceResponse(
                ok: true, message: "pong", daemonStatus: makeDaemonStatus(protocolVersion: SpacesWireProtocol.version - 1, activeSessionCount: 2))
            let message = try XCTUnwrap(TerminalService.daemonWireIncompatibilityDetails(response)?.message)
            XCTAssertTrue(message.contains("Restart the daemon"))
            // Impact suffix appears when a restart would interrupt running work.
            XCTAssertTrue(message.contains("Restarting stops"))
            XCTAssertThrowsError(try TerminalService.assertDaemonWireCompatible(response)) { error in
                guard case TerminalServiceError.daemonWireIncompatible(let incompatibility) = error else {
                    return XCTFail("Expected daemonWireIncompatible, got \(error)")
                }
                XCTAssertEqual(incompatibility.verdict, .daemonTooOld)
                XCTAssertTrue(incompatibility.canRestartDaemon)
                XCTAssertEqual(incompatibility.status?.activeSessionCount, 2)
            }
        }

        func testDaemonWireIncompatibleWhenClientIsOlder() throws {
            let response = TerminalServiceResponse(
                ok: true, message: "pong", daemonStatus: makeDaemonStatus(protocolVersion: SpacesWireProtocol.version + 1))
            let message = try XCTUnwrap(TerminalService.daemonWireIncompatibilityDetails(response)?.message)
            XCTAssertTrue(message.contains("Update Spaces"))
            XCTAssertThrowsError(try TerminalService.assertDaemonWireCompatible(response)) { error in
                guard case TerminalServiceError.daemonWireIncompatible(let incompatibility) = error else {
                    return XCTFail("Expected daemonWireIncompatible, got \(error)")
                }
                XCTAssertEqual(incompatibility.verdict, .clientTooOld)
                XCTAssertFalse(incompatibility.canRestartDaemon)
            }
        }

        func testDaemonWireIncompatibleWhenStatusIsMissing() throws {
            // A daemon predating wire-version negotiation omits daemonStatus entirely; treat it as too old.
            let response = TerminalServiceResponse(ok: true, message: "pong")
            XCTAssertNotNil(TerminalService.daemonWireIncompatibilityDetails(response)?.message)
        }

        private func makeDaemonStatus(protocolVersion: Int, activeSessionCount: Int = 0) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: "0.1.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: activeSessionCount,
                protocolVersion: protocolVersion)
        }

        func testCreateSessionRequestTimeoutUsesPositiveEnvironmentOverride() {
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: ["SPACESD_CREATE_TIMEOUT": "45"]), 45)
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: ["SPACESD_CREATE_TIMEOUT": "0"]), 30)
            XCTAssertEqual(TerminalService.createSessionRequestTimeout(environment: [:]), 30)
        }

        private func makeTemporaryDirectory() throws -> URL {
            let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
                "spacesd tests \(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }

        private func makeExecutableFile(at url: URL) throws {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// `isInstalled` is stated independently of `source` on purpose: what a profile IS decides the
        /// candidate list, and how it was discovered is only carried along for the error text. Stating both
        /// here is what lets a test cover a profile whose route and identity disagree.
        private func makeProfile(isInstalled: Bool, source: SpacesProfileSource) -> SpacesProfile {
            let root = "/tmp/spaces-profile-\(UUID().uuidString)"
            return SpacesProfile(
                source: source, databasePath: "\(root)/spaces.db", rootDirectory: root, isInstalledProfile: isInstalled,
                runtimeDirectory: "\(root)/runtime", ipcNotificationObject: "spaces.profile.test", developmentContext: nil, branchSlug: nil,
                worktreeHash: nil)
        }

        /// A checkout-style build directory whose `spacesd` exists but is not executable (the observed
        /// failure), an installed link that is executable, and a working directory with no `.build` tree so
        /// the checkout-relative candidates can't resolve the real daemon this suite was built alongside.
        private struct DaemonResolutionLayout {
            let root: URL
            let buildCLI: URL
            let installedDaemon: URL
            let workingDirectory: URL
            let fileManager: FileManager
        }

        private func makeDaemonResolutionLayout() throws -> DaemonResolutionLayout {
            let root = try makeTemporaryDirectory()
            let buildDirectory = root.appendingPathComponent("checkout/apps/macos/.build/debug", isDirectory: true)
            let installedBinDirectory = root.appendingPathComponent("home/.spaces/bin", isDirectory: true)
            let workingDirectory = root.appendingPathComponent("cwd", isDirectory: true)
            for directory in [buildDirectory, installedBinDirectory, workingDirectory] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let buildCLI = buildDirectory.appendingPathComponent("spaces", isDirectory: false)
            try makeExecutableFile(at: buildCLI)
            try Data().write(to: buildDirectory.appendingPathComponent("spacesd", isDirectory: false))
            let installedDaemon = installedBinDirectory.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: installedDaemon)
            return DaemonResolutionLayout(
                root: root, buildCLI: buildCLI, installedDaemon: installedDaemon, workingDirectory: workingDirectory,
                fileManager: FixedWorkingDirectoryFileManager(workingDirectoryPath: workingDirectory.path))
        }

        /// Builds the daemon a checkout-relative candidate would find: a `.build/debug/spacesd` under the
        /// working directory the process was started in, standing in for an unrelated checkout.
        private func makeCheckoutRelativeDaemon(in layout: DaemonResolutionLayout) throws -> URL {
            let buildDirectory = layout.workingDirectory.appendingPathComponent("apps/macos/.build/debug", isDirectory: true)
            try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
            let daemon = buildDirectory.appendingPathComponent("spacesd", isDirectory: false)
            try makeExecutableFile(at: daemon)
            return daemon
        }
    }

    /// Pins `currentDirectoryPath` so daemon resolution's checkout-relative candidates are controlled by
    /// the test rather than by wherever the test runner happens to have been launched.
    private final class FixedWorkingDirectoryFileManager: FileManager {
        private let workingDirectoryPath: String

        init(workingDirectoryPath: String) {
            self.workingDirectoryPath = workingDirectoryPath
            super.init()
        }

        override var currentDirectoryPath: String { workingDirectoryPath }
    }
#endif
