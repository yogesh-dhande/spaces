import ArgumentParser
import Darwin
import Foundation
import spacesterminalcore
import systembridge
import workspacecore

/// The QA profile lane: the INSTALLED Spaces build, run against a throwaway profile seeded from the
/// user's own, so a QA sweep can create, mutate, and delete anything it likes while `~/.spaces`, its
/// daemon, and its database are never opened.
///
/// Everything here addresses the QA profile explicitly, by path, and nothing it does can reach another
/// profile: the app is launched with `SPACES_DB_PATH` naming the QA database (a binding that exists only
/// in the launched process's environment), the app to stop is the one named in the QA profile's own
/// app-owner lease, and the daemon to stop is the one answering the QA profile's own terminal-service
/// socket. Neither the installed app nor the `dev.usespaces.spacesd` LaunchAgent job is ever signalled.
struct QAProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "qa-profile", abstract: "Run the installed Spaces build against a throwaway QA profile seeded from ~/.spaces.",
        subcommands: [
            QAProfileCreateCommand.self, QAProfileLaunchCommand.self, QAProfileStopCommand.self, QAProfileRemoveCommand.self,
            QAProfileDeployRemoteCommand.self,
        ])
}

private struct QAProfileCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Seed the QA profile from this account's installed profile.")

    func run() throws {
        let homeDirectoryURL = QAProfileLane.homeDirectoryURL()
        try QAProfileSeed.seed(
            installedRootDirectory: SpacesProfile.installedRootDirectory(homeDirectoryURL: homeDirectoryURL),
            qaRootDirectory: QAProfileSeed.rootDirectory(homeDirectoryURL: homeDirectoryURL))
        QAProfileLane.printPaths(profile: try QAProfileLane.resolvedProfile())
    }
}

private struct QAProfileLaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch", abstract: "Launch the installed Spaces app on the QA profile.")

    /// The installed app is launched exactly as the user's own copy runs, with one addition to its
    /// environment: `SPACES_DB_PATH` naming the QA database. That binding is what makes the whole process
    /// tree QA's, since the daemon the app starts inherits it, and it never reaches the user's shell.
    ///
    /// Nothing pins the daemon: the installed app finds its own `Contents/Resources/spacesd` sibling
    /// (`TerminalService.resolveExecutableURL`), and it spawns that daemon directly rather than kickstarting
    /// the LaunchAgent, because the LaunchAgent route is reserved for the installed profile and the QA
    /// profile is not it (`TerminalService.resolveStartPlan`).
    func run() throws {
        let profile = try QAProfileLane.existingProfile()
        let appExecutableURL = QAProfileLane.installedAppExecutableURL
        guard FileManager.default.isExecutableFile(atPath: appExecutableURL.path) else {
            throw ValidationError("There is no installed Spaces app at \(QAProfileLane.installedAppBundleURL.path).")
        }
        try QAProfileLane.refuseRedirectingEnvironment(action: "launch the QA app")
        if let owner = try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile) {
            throw ValidationError("The QA profile is already owned by a running Spaces app (pid \(owner.pid)). Run `qa-profile stop` first.")
        }

        let environment = QAProfileEnvironment.environmentForInstalledProcess(
            executablePath: appExecutableURL.path, databasePath: profile.databasePath, base: ProcessInfo.processInfo.environment)

        let logURL = QAProfileLane.appLogURL(profile: profile)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logURL.path) else {
            throw ValidationError("Could not open \(logURL.path) for the QA app's output.")
        }

        let process = Process()
        process.executableURL = appExecutableURL
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()

        let pid = process.processIdentifier
        try QAProfileLane.waitForAppOwner(profile: profile, pid: pid, process: process, logURL: logURL)
        print("app-pid\t\(pid)")
        print("app-log\t\(logURL.path)")
        QAProfileLane.printPaths(profile: profile)
    }
}

private struct QAProfileStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop the QA profile's Spaces app and daemon.")

    func run() throws {
        let profile = try QAProfileLane.existingProfile()
        try QAProfileLane.stopApp(profile: profile)
        try QAProfileLane.stopDaemon(profile: profile)
    }
}

private struct QAProfileRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Delete the QA profile once nothing is running on it.")

    /// Only the QA root is deleted, and only once nothing holds it. The remote QA profile is a separate
    /// profile on a separate device with its own lifecycle: remove it with
    /// `spacese2e profile remove --remote qa`.
    func run() throws {
        let rootDirectory = QAProfileLane.rootDirectory()
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else {
            throw ValidationError("There is no QA profile at \(rootDirectory.path).")
        }
        let profile = try QAProfileLane.resolvedProfile()
        if let owner = try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile) {
            throw ValidationError("The QA profile is still owned by a running Spaces app (pid \(owner.pid)). Run `qa-profile stop` first.")
        }
        try QAProfileLane.requireNoDaemon(profile: profile)
        try FileManager.default.removeItem(at: rootDirectory)
        print("Removed \(rootDirectory.path).")
    }
}

private struct QAProfileDeployRemoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy-remote",
        abstract: "Install the released Linux daemon into the device's `qa` profile and pair the QA Mac profile with it.")

    /// The RELEASED artifact for the installed Mac app's version, not a build of this checkout: the lane
    /// exists to QA a shipped build, and a Mac release and its Linux daemon artifacts are published
    /// together under one tag, so the tag the Mac app reports is the one that names the daemon it was
    /// released with.
    func run() throws {
        let device = try RemoteDevice.fromEnvironment()
        let profile = try QAProfileLane.existingProfile()
        // Before the first remote command. Pairing is redeemed through the installed CLI, which refuses a
        // redirecting environment, and reaching that refusal at the end of the command would mean the
        // release is already installed and the remote daemon already started on a run that cannot finish.
        try QAProfileLane.refuseRedirectingEnvironment(action: "deploy the remote QA daemon")
        let version = try QAProfileLane.installedAppVersion()
        let tag = "v\(version)"
        let architecture = try QAProfileLane.remoteUbuntuArchitecture(device: device)
        let archiveName = "spacesd-ubuntu-24.04-\(architecture).tar.gz"

        let downloadDirectory = try QAProfileLane.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloadDirectory) }
        try QAProfileLane.downloadReleaseArchive(tag: tag, archiveName: archiveName, into: downloadDirectory)
        try QAProfileLane.verifyArchiveDigest(archiveName: archiveName, in: downloadDirectory)

        print("Installing \(archiveName) from \(tag) into remote profile \(QAProfileLane.remoteProfileName) on \(device.destination)...")
        try QAProfileLane.installRemoteDaemon(device: device, archiveURL: downloadDirectory.appendingPathComponent(archiveName, isDirectory: false))
        print(try device.runReportingScript(QAProfileLane.waitForRemoteDaemonScript()).detail)

        let pairingLink = try QAProfileLane.remotePairingLink(device: device)
        print(try QAProfileLane.redeemPairingLink(pairingLink, profile: profile))
    }
}

/// The paths, process lookups, and remote steps the five verbs share.
private enum QAProfileLane {
    /// The profile name the device hosts this lane's daemon under. It is a development profile on that
    /// device like any other, so `spacese2e profile list --remote` shows it and
    /// `spacese2e profile remove --remote qa` tears it down.
    static let remoteProfileName = "qa"

    /// Where the released Linux daemon artifacts are published, matching the tag the Mac release created.
    static let releaseRepository = "yogesh-dhande/spaces"

    static let installedAppBundleURL = SpacesBinaryLayout.installedAppBundleURL()

    static var installedAppExecutableURL: URL { installedAppBundleURL.appendingPathComponent("Contents/MacOS/SpacesApp", isDirectory: false) }

    /// The installed app's own `spaces` CLI. Pairing is redeemed through it rather than through a
    /// repo-built CLI so the client half of the pairing is the shipped code too.
    static var installedCLIURL: URL { SpacesBinaryLayout.appResourceURL(for: .spaces, appBundleURL: installedAppBundleURL) }

    static func homeDirectoryURL() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Refuses to start a shipped binary from a shell that carries a binding which would redirect it off
    /// the QA profile. The launched app and the launched CLI both inherit this process's environment, so
    /// the check belongs here rather than in either command; `QAProfileEnvironment` holds the names and
    /// says why the answer is a refusal instead of a scrub.
    static func refuseRedirectingEnvironment(action: String) throws {
        guard let refusal = QAProfileEnvironment.redirectingRefusal(in: ProcessInfo.processInfo.environment, action: action) else { return }
        throw ValidationError(refusal)
    }

    static func rootDirectory() -> URL { QAProfileSeed.rootDirectory(homeDirectoryURL: homeDirectoryURL()) }

    /// The QA profile as product code resolves it, from the same `SPACES_DB_PATH` binding the launched app
    /// gets, so this process and the launched one agree on every path without either inheriting a binding
    /// from the shell. Resolution creates the profile root and runtime directory, which is why callers that
    /// must not create anything check the root themselves first.
    static func resolvedProfile() throws -> SpacesProfile {
        let databasePath = QAProfileSeed.databaseURL(profileRoot: rootDirectory()).path
        return try SpacesProfile.resolve(
            environment: [SpacesProfile.databasePathEnvironmentVariable: databasePath], homeDirectoryURL: homeDirectoryURL(),
            currentDirectoryPath: FileManager.default.currentDirectoryPath)
    }

    /// The QA profile, refusing when it has not been seeded yet. A profile whose database is missing is not
    /// a profile the installed build can be pointed at.
    static func existingProfile() throws -> SpacesProfile {
        let databaseURL = QAProfileSeed.databaseURL(profileRoot: rootDirectory())
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ValidationError("There is no QA profile database at \(databaseURL.path). Run `qa-profile create` first.")
        }
        return try resolvedProfile()
    }

    static func appLogURL(profile: SpacesProfile) -> URL {
        URL(fileURLWithPath: profile.rootDirectory, isDirectory: true).appendingPathComponent("qa-app.log", isDirectory: false)
    }

    static func printPaths(profile: SpacesProfile) {
        print("profile-root\t\(profile.rootDirectory)")
        print("database-path\t\(profile.databasePath)")
        print(
            "client-database-path\t\(QAProfileSeed.clientDatabaseURL(profileRoot: URL(fileURLWithPath: profile.rootDirectory, isDirectory: true)).path)"
        )
        print("runtime-dir\t\(profile.runtimeDirectory)")
    }

    /// Waits until the QA profile's app-owner lease names the launched process. The lease is the app's own
    /// statement that it has taken this profile, so it is what proves the launch reached the profile the
    /// binding named rather than some other one.
    /// Waits for the launched app to take the QA profile's app-owner lease, and leaves nothing running if
    /// it does not.
    ///
    /// The lease is how every other verb finds this app, so an app that never takes it is an app `stop`
    /// cannot reach: it would keep serving the QA profile with no handle on it but a pid this command is
    /// about to throw away. The launch is undone instead, and only ever by the pid this process spawned.
    static func waitForAppOwner(profile: SpacesProfile, pid: Int32, process: Process, logURL: URL) throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let owner = try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile), owner.pid == pid { return }
            guard process.isRunning else { throw ValidationError("The QA app exited during launch. Its output is in \(logURL.path).") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        terminate(process: process, pid: pid)
        throw ValidationError(
            "The QA app (pid \(pid)) did not take the QA profile's app-owner lease and has been stopped. Its output is in \(logURL.path).")
    }

    /// Asks a process this lane spawned to exit, and reports when it will not. `Process.terminate` sends
    /// `SIGTERM` to a child this process owns, so nothing here can reach a pid the lane did not start.
    static func terminate(process: Process, pid: Int32) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard process.isRunning else { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        print("The QA app (pid \(pid)) has not exited after being asked to. Stop it before launching again.")
    }

    /// Stops the app that owns the QA profile.
    ///
    /// The pid comes from the QA profile's own app-owner lease, which is written inside the QA root, so it
    /// can only ever name the app serving this profile. The executable it records is checked against the
    /// installed bundle as well: this lane launches nothing else, so anything else holding the lease is a
    /// situation to report rather than to signal.
    static func stopApp(profile: SpacesProfile) throws {
        guard let owner = try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile) else {
            print("No Spaces app owns the QA profile.")
            return
        }
        let expectedPath = SpacesProfile.canonicalPath(installedAppExecutableURL.path)
        guard SpacesProfile.canonicalPath(owner.executablePath) == expectedPath else {
            throw ValidationError("The QA profile is owned by pid \(owner.pid) running \(owner.executablePath), which is not \(expectedPath).")
        }
        kill(owner.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile) == nil {
                print("Stopped the QA app (pid \(owner.pid)).")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ValidationError("The QA app (pid \(owner.pid)) did not exit after being asked to.")
    }

    /// Refuses unless the QA profile's daemon is gone, deciding on the profile's own instance lock rather
    /// than on whether a ping comes back.
    ///
    /// Silence is not absence: a ping that times out, or whose response does not decode, is as much a
    /// daemon too busy to answer as it is no daemon at all, and deleting the profile root under a live one
    /// leaves it writing into paths that no longer exist. The instance lock settles it, because a daemon
    /// holds its profile's lock for as long as it runs and the record names the pid, so a lock whose owner
    /// is gone reads as absent rather than as a refusal. The socket file cannot settle it either way: the
    /// daemon unlinks it when it binds, not when it exits, so it outlives every stopped daemon. A ping is
    /// still asked once the lock says nothing, which catches a daemon serving this profile without having
    /// taken the lock.
    static func requireNoDaemon(profile: SpacesProfile) throws {
        if let lockOwner = try TerminalServiceInstanceLock.activeOwner(path: TerminalServicePaths.instanceLockPath(profile: profile)) {
            throw ValidationError("The QA profile's spacesd is still running (pid \(lockOwner.processID)). Run `qa-profile stop` first.")
        }
        if let response = daemonResponse(profile: profile, command: .ping), response.ok {
            throw ValidationError(
                "The QA profile's spacesd is still answering (pid \(response.servicePID.map { String($0) } ?? "unknown")). Run `qa-profile stop` first."
            )
        }
    }

    /// Stops the daemon serving the QA profile by asking it to shut down over its own socket.
    ///
    /// The socket is named from the QA profile's runtime directory, so it addresses that daemon and no
    /// other. A pgrep would not: the QA daemon is the very same `spacesd` binary as the user's installed
    /// one, and matching by executable path would match the daemon this lane must never touch.
    static func stopDaemon(profile: SpacesProfile) throws {
        let socketPath = try TerminalServicePaths.socketPath(profile: profile)
        guard FileManager.default.fileExists(atPath: socketPath) else {
            print("No spacesd is serving the QA profile.")
            return
        }
        guard let response = daemonResponse(profile: profile, command: .shutdown), let servicePID = response.servicePID else {
            print("Nothing answered the QA profile's spacesd socket at \(socketPath).")
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if kill(servicePID, 0) != 0, errno != EPERM {
                print("Stopped the QA spacesd (pid \(servicePID)).")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ValidationError("The QA spacesd (pid \(servicePID)) accepted the shutdown request but has not exited.")
    }

    /// One request to the QA daemon, or `nil` when nothing answers. A socket with no daemon behind it is a
    /// normal outcome for both callers here (a leftover file, or a daemon mid-exit), which is why it is a
    /// value rather than a thrown error.
    static func daemonResponse(profile: SpacesProfile, command: TerminalServiceCommand) -> TerminalServiceResponse? {
        guard let socketPath = try? TerminalServicePaths.socketPath(profile: profile), FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }
        return try? TerminalServiceClient.send(request: TerminalServiceRequest(command: command), socketPath: socketPath, timeout: 5)
    }

    static func installedAppVersion() throws -> String {
        guard let version = InstalledSpacesVersion.appBundleVersion(bundleURL: installedAppBundleURL) else {
            throw ValidationError("Could not read a version from \(installedAppBundleURL.path)/Contents/Info.plist.")
        }
        return version
    }

    /// The device's architecture, refusing anything the released artifacts are not built for. The daemon
    /// artifacts are published for Ubuntu 24.04 only, so the probe reports the device's distribution too
    /// and the refusal names what it found.
    static func remoteUbuntuArchitecture(device: RemoteDevice) throws -> String {
        let output = try device.run(
            script: """
                set -u
                printf 'os=%s\\n' "$(uname -s)"
                printf 'arch=%s\\n' "$(uname -m)"
                if [ -r /etc/os-release ]; then
                    . /etc/os-release
                    printf 'linux_id=%s\\n' "${ID:-}"
                    printf 'linux_version_id=%s\\n' "${VERSION_ID:-}"
                fi
                """)
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        guard fields["os"] == "Linux", fields["linux_id"] == "ubuntu", fields["linux_version_id"] == "24.04" else {
            throw ValidationError(
                "\(device.destination) is not an Ubuntu 24.04 Linux device (os=\(fields["os"] ?? "") id=\(fields["linux_id"] ?? "") "
                    + "version=\(fields["linux_version_id"] ?? "")), and released Spaces daemon artifacts are built only for that.")
        }
        switch fields["arch"] ?? "" {
        case "x86_64", "amd64", "x64": return "x86_64"
        case "arm64", "aarch64": return "arm64"
        default: throw ValidationError("\(device.destination) reports an unsupported architecture: \(fields["arch"] ?? "unknown").")
        }
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spaces-qa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func downloadReleaseArchive(tag: String, archiveName: String, into directory: URL) throws {
        do {
            _ = try Shell.runAndCapture([
                "gh", "release", "download", tag, "--repo", releaseRepository, "--pattern", "\(archiveName)*", "--dir", directory.path,
            ])
        } catch {
            throw ValidationError("Could not download \(archiveName) from release \(tag) of \(releaseRepository): \(error.localizedDescription)")
        }
        for name in [archiveName, "\(archiveName).sha256"] {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name, isDirectory: false).path) else {
                throw ValidationError("Release \(tag) of \(releaseRepository) does not carry \(name).")
            }
        }
    }

    /// Checks the archive against the digest published beside it, before anything is uploaded to the
    /// device. The digest file names the archive with no directory, so the check runs in the directory
    /// holding both.
    static func verifyArchiveDigest(archiveName: String, in directory: URL) throws {
        do { _ = try Shell.runAndCapture(["shasum", "-a", "256", "-c", "\(archiveName).sha256"], cwd: directory.path) } catch {
            throw ValidationError("\(archiveName) does not match its published sha256: \(error.localizedDescription)")
        }
    }

    /// Uploads the archive and runs the installer it carries, which is what creates the device's `qa`
    /// profile: `install.sh --profile qa` lays everything that profile owns under
    /// `~/.spaces-dev/profiles/spaces/qa/` and runs it as the `spacesd@qa.service` unit instance. The
    /// device's installed `~/.spaces` daemon is untouched, and re-running simply reinstalls.
    /// Where the archive lands on the device, relative to the login home.
    ///
    /// Relative because `scp` speaks SFTP on current macOS, and SFTP resolves a path itself instead of
    /// handing it to a remote shell: a target of `host:$HOME/...` creates a directory literally named
    /// `$HOME`. A path with no leading slash is resolved against the login home by the SFTP server, which
    /// is the same directory the SSH-side commands reach through `$HOME`, so the two agree on one location.
    static let remoteStagingRelativePath = ".cache/spaces-qa-deploy"

    static func installRemoteDaemon(device: RemoteDevice, archiveURL: URL) throws {
        let stagingDirectory = "$HOME/\(remoteStagingRelativePath)"
        let remoteArchivePath = "\(stagingDirectory)/\(archiveURL.lastPathComponent)"
        _ = try device.run(script: "set -eu\nrm -rf \(stagingDirectory)\nmkdir -p \(stagingDirectory)")
        try uploadFile(device: device, localURL: archiveURL, remotePath: "\(remoteStagingRelativePath)/\(archiveURL.lastPathComponent)")
        // The installer's own output is printed rather than discarded: an SSH exit status cannot report
        // whether it worked (Tailscale SSH reports 0 for every remote command), so the readiness wait that
        // follows is what decides, and this is what tells the operator why it did not become ready.
        print(
            try device.run(
                script: """
                    set -eu
                    mkdir -p \(stagingDirectory)/install
                    tar -xzf \(remoteArchivePath) -C \(stagingDirectory)/install --strip-components=1
                    \(stagingDirectory)/install/install.sh --profile \(remoteProfileName)
                    """
            ).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func uploadFile(device: RemoteDevice, localURL: URL, remotePath: String) throws {
        var arguments = ["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes"]
        if let sshPort = device.sshPort { arguments += ["-P", String(sshPort)] }
        arguments += [localURL.path, "\(device.destination):\(remotePath)"]
        do { _ = try Shell.runAndCapture(arguments) } catch {
            throw ValidationError("Uploading \(localURL.lastPathComponent) to \(device.destination) failed: \(error.localizedDescription)")
        }
    }

    /// Readiness is the profile's own two facts: user systemd holds its unit instance active, and the
    /// profile's own CLI gets an answer out of that daemon. There is no well-known port to probe, since a
    /// development profile's daemon assigns itself one.
    static func waitForRemoteDaemonScript() -> String {
        """
        set -u
        # Reports its outcome in a trailing ##ok/##error marker line and always exits 0; see runReportingScript.
        unit='spacesd@\(remoteProfileName).service'
        cli="$HOME/.spaces-dev/profiles/spaces/\(remoteProfileName)/daemon/current/bin/spaces"
        deadline=$(( $(date +%s) + 60 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            if systemctl --user is-active --quiet "$unit" && "$cli" terminal list >/dev/null 2>&1; then
                printf '\(RemoteDevice.okMarker)\t%s is active and answering its own CLI.\\n' "$unit"
                exit 0
            fi
            sleep 0.5
        done
        printf '\(RemoteDevice.errorMarker)\t%s did not become ready within 60 seconds.\\n' "$unit"
        """
    }

    /// Opens a pairing window on the remote QA profile's daemon and returns the `spaces://pair` link it
    /// printed. The remote profile's OWN CLI is run with no environment prefix, because a profile-rooted
    /// binary resolves its profile from where it sits; the device's installed CLI is never involved.
    static func remotePairingLink(device: RemoteDevice) throws -> String {
        let cli = "$HOME/.spaces-dev/profiles/spaces/\(remoteProfileName)/daemon/current/bin/spaces"
        let output = try device.run(script: "set -eu\n\(cli) device pair --json")
        guard let data = output.data(using: .utf8), let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let link = payload["pairingLink"] as? String, !link.isEmpty
        else { throw ValidationError("The remote \(remoteProfileName) profile did not return a pairing link. Output:\n\(output)") }
        return link
    }

    /// Redeems the pairing link from the QA Mac profile, using the installed `spaces` CLI with
    /// `SPACES_DB_PATH` naming the QA database so the credential and the paired-device row land in the QA
    /// profile rather than in `~/.spaces`.
    static func redeemPairingLink(_ link: String, profile: SpacesProfile) throws -> String {
        try refuseRedirectingEnvironment(action: "pair the QA profile")
        let process = Process()
        process.executableURL = installedCLIURL
        process.arguments = ["device", "pair", "--link", link]
        process.environment = QAProfileEnvironment.environmentForInstalledProcess(
            executablePath: installedCLIURL.path, databasePath: profile.databasePath, base: ProcessInfo.processInfo.environment)
        // One pipe for both streams: draining two in turn deadlocks whenever the undrained one fills, and
        // the whole point of reading them here is to report what the CLI said when pairing fails.
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = (String(data: outputData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ValidationError("Pairing the QA profile with the remote \(remoteProfileName) profile failed: \(text)")
        }
        return text
    }
}
