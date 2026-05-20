import ArgumentParser
import Foundation
import spacesterminalcore
import systembridge
import workspacecore

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile", abstract: "Inspect the resolved Spaces profile and desktop-control state.",
        subcommands: [
            ProfileShowCommand.self, ProfileAppOwnerCommand.self, ProfileDesktopControlOwnerCommand.self, ProfileWaitForDesktopControlCommand.self,
        ])
}

struct ProfileShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show the resolved profile paths for this Spaces binary.")

    @Flag(name: .long, help: "Emit shell exports for SPACES_DB_PATH and SPACES_RUNTIME_DIR.") var shell = false
    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let profile = try SpacesProfile.current()
        let payload = ProfilePayload(profile: profile)
        if shell {
            print("export \(SpacesProfile.databasePathEnvironmentVariable)=\(shellQuoted(profile.databasePath))")
            print("export \(SpacesProfile.runtimeDirectoryEnvironmentVariable)=\(shellQuoted(profile.runtimeDirectory))")
            return
        }
        if json {
            try emitProfileJSON(payload)
            return
        }

        print("source\t\(profile.source.rawValue)")
        print("profile-root\t\(profile.rootDirectory)")
        print("database-path\t\(profile.databasePath)")
        print("runtime-dir\t\(profile.runtimeDirectory)")
        print("ipc-object\t\(profile.ipcNotificationObject)")
        if let worktreeRoot = payload.worktreeRoot { print("worktree-root\t\(worktreeRoot)") }
        if let branch = payload.branchName { print("branch\t\(branch)") }
    }
}

struct ProfileAppOwnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "app-owner", abstract: "Show the running Spaces app owner for this profile, if any.")

    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let profile = try SpacesProfile.current()
        let owner = try SpacesLeaseCoordinator.currentProfileAppOwner(profile: profile)
        let payload = LeaseStatePayload(available: owner == nil, profileRoot: profile.rootDirectory, owner: owner)
        if json {
            try emitProfileJSON(payload)
            return
        }

        guard let owner else {
            print("No running Spaces app owns profile \(profile.rootDirectory).")
            return
        }
        print("pid=\(owner.pid)\texecutable=\(owner.executablePath)\tprofile-root=\(owner.profileRoot ?? profile.rootDirectory)")
    }
}

struct ProfileDesktopControlOwnerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "desktop-control-owner", abstract: "Show which Spaces instance owns desktop-global control.")

    @Flag(name: .long, help: "Emit JSON instead of text.") var json = false

    func run() throws {
        let owner = try SpacesLeaseCoordinator.currentDesktopControlOwner()
        let payload = LeaseStatePayload(available: owner == nil, profileRoot: owner?.profileRoot, owner: owner)
        if json {
            try emitProfileJSON(payload)
            return
        }

        guard let owner else {
            print("Desktop control is available.")
            return
        }
        print("pid=\(owner.pid)\texecutable=\(owner.executablePath)\tprofile-root=\(owner.profileRoot ?? "unknown")")
    }
}

struct ProfileWaitForDesktopControlCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait-for-desktop-control", abstract: "Wait until no Spaces instance owns desktop-global control.")

    @Option(name: .long, help: "Wait timeout in seconds. Defaults to SPACES_REAL_SYSTEM_WAIT_TIMEOUT_SECONDS or 600.") var timeoutSeconds: Double?

    func run() throws {
        let envTimeoutSeconds = Double(ProcessInfo.processInfo.environment["SPACES_REAL_SYSTEM_WAIT_TIMEOUT_SECONDS"] ?? "")
        let effectiveTimeoutSeconds = timeoutSeconds ?? envTimeoutSeconds ?? 600
        if let owner = try SpacesLeaseCoordinator.currentDesktopControlOwner() { deliverDesktopControlBusyNotification(owner: owner) }
        let available = try SpacesLeaseCoordinator.waitForDesktopControlAvailability(timeoutSeconds: effectiveTimeoutSeconds) { line in print(line) }
        if available {
            print("Desktop control is available.")
            return
        }

        let owner = try SpacesLeaseCoordinator.currentDesktopControlOwner()
        let detail =
            owner.map { "Owner pid=\($0.pid) executable=\($0.executablePath) profile=\($0.profileRoot ?? "unknown")." }
            ?? "Owner metadata is no longer available."
        let message = "Desktop control remained busy for \(Int(effectiveTimeoutSeconds)) seconds. \(detail) Retry this workflow once the owner exits."
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        throw ExitCode.failure
    }
}

private struct ProfilePayload: Encodable {
    let source: String
    let databasePath: String
    let profileRoot: String
    let runtimeDirectory: String
    let ipcObject: String
    let worktreeRoot: String?
    let branchName: String?

    init(profile: SpacesProfile) {
        source = profile.source.rawValue
        databasePath = profile.databasePath
        profileRoot = profile.rootDirectory
        runtimeDirectory = profile.runtimeDirectory
        ipcObject = profile.ipcNotificationObject
        worktreeRoot = profile.developmentContext?.worktreeRoot
        branchName = profile.developmentContext?.branchName
    }
}

private struct LeaseStatePayload: Encodable {
    let available: Bool
    let profileRoot: String?
    let owner: SpacesProcessLeaseOwner?
}

private func emitProfileJSON<T: Encodable>(_ payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    guard let output = String(data: data, encoding: .utf8) else { throw ValidationError("Failed to encode profile payload.") }
    print(output)
}

private func shellQuoted(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "'", with: #"'\"'\"'"#)
    return "'\(escaped)'"
}

func deliverDesktopControlBusyNotification(owner: SpacesProcessLeaseOwner) {
    do {
        // Use `osascript` directly so dev CLI builds deliver notifications the same
        // way as the manual probe used in real-system workflows.
        _ = try Shell.runAndCapture(["osascript", "-e", desktopControlBusyNotificationScript(owner: owner)])
    } catch { fputs("spaces: Failed to send desktop control notification: \(error.localizedDescription)\n", stderr) }
}

func desktopControlBusyNotificationScript(owner: SpacesProcessLeaseOwner) -> String {
    let ownerName = URL(fileURLWithPath: owner.executablePath).lastPathComponent
    let profileName = owner.profileRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown-profile"
    let title = "Close Spaces When You're Done"
    let subtitle = "A real-system Spaces workflow is waiting"
    let body = "Desktop control is owned by \(ownerName) (pid \(owner.pid), profile \(profileName)). Quit that instance so the harness can continue."
    return """
        display notification \(appleScriptStringLiteral(body)) with title \(appleScriptStringLiteral(title)) subtitle \(appleScriptStringLiteral(subtitle))
        """
}

private func appleScriptStringLiteral(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(
        of: "\r", with: " "
    ).replacingOccurrences(of: "\n", with: " ")
    return "\"\(escaped)\""
}
