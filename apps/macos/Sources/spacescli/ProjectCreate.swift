import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore

/// What `spaces project create` and `spaces_project_create` report, built the same way whether this
/// machine's daemon or a paired device created the project, so both paths print one row format and
/// return one JSON shape.
struct CreatedProjectReport: Equatable {
    let message: String
    let project: TerminalServiceProfileProjectSummary
    let defaultWorkspaceID: String
    let spacesYAMLImported: Bool

    var row: String {
        "Created project \(project.id)\tname=\(project.name)\tdir=\(project.dir)\tworkspace=\(defaultWorkspaceID)\tspaces.yaml=\(spacesYAMLImported ? "imported" : "none")"
    }

    var profileResponse: TerminalServiceProfileCommandResponse {
        TerminalServiceProfileCommandResponse(
            message: message, project: project, defaultWorkspaceID: defaultWorkspaceID, spacesYAMLImported: spacesYAMLImported)
    }

    /// Reads the local daemon's `projectCreate` response.
    init(profileResponse response: TerminalServiceProfileCommandResponse) throws {
        guard let project = response.project, let defaultWorkspaceID = response.defaultWorkspaceID,
            let spacesYAMLImported = response.spacesYAMLImported
        else { throw MissingCreatedProjectError() }
        self.init(message: response.message, project: project, defaultWorkspaceID: defaultWorkspaceID, spacesYAMLImported: spacesYAMLImported)
    }

    /// Reads a paired device's `createProject` response. The project's summary comes from the refreshed
    /// overview the mutation carries, looked up by the created project's id.
    init(deviceResponse response: SpacesDeviceAPIResponse) throws {
        guard let projectID = response.projectID, let defaultWorkspaceID = response.workspaceID, let spacesYAMLImported = response.spacesYAMLImported,
            let summary = response.overview?.projects.first(where: { $0.id == projectID })
        else { throw MissingCreatedProjectError() }
        self.init(
            message: response.message,
            project: TerminalServiceProfileProjectSummary(
                id: summary.id, name: summary.name, dir: summary.dir, isGitRepo: summary.isGitRepo, defaultBranch: summary.defaultBranch),
            defaultWorkspaceID: defaultWorkspaceID, spacesYAMLImported: spacesYAMLImported)
    }

    init(message: String, project: TerminalServiceProfileProjectSummary, defaultWorkspaceID: String, spacesYAMLImported: Bool) {
        self.message = message
        self.project = project
        self.defaultWorkspaceID = defaultWorkspaceID
        self.spacesYAMLImported = spacesYAMLImported
    }
}

/// A daemon that reports a create as successful always returns the project it created.
struct MissingCreatedProjectError: LocalizedError {
    var errorDescription: String? { "The daemon reported the project as created but did not return it." }
}

/// A paired device's daemon speaks another wire protocol than this build, so the create was never sent.
struct DeviceWireIncompatibleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Creates a project on this machine's daemon (`device` is nil) or on a paired device. Neither path may
/// replace folders an earlier import of the same git URL left behind: that needs the Mac app's
/// confirmation.
func createProject(_ source: TerminalServiceProjectCreateSource, device: SpacesPairedDeviceRecord?) throws -> CreatedProjectReport {
    guard let device else {
        return try CreatedProjectReport(
            profileResponse: TerminalService.sendProfileCommand(.projectCreate(source), timeout: SpacesDeviceAPICommand.projectCreateTimeoutSeconds))
    }
    let context = DeviceRequestContext(device: device, clientApp: cliDeviceClientApp())
    return try createProject(
        source, onDeviceNamed: device.name, daemonStatus: { try SpacesDeviceClient.daemonStatus(context: context) },
        create: { projectDir, gitURL in
            try SpacesDeviceClient.createProject(
                projectDir: projectDir, gitURL: gitURL, config: nil, replaceExistingManagedDirectories: false, context: context)
        })
}

/// Creates the project on a paired device once a fresh status read shows its daemon speaks this build's
/// wire protocol, and refuses before sending anything otherwise. A daemon on another protocol reads the
/// create under a different contract: an older one replaces leftover managed folders without asking,
/// skips the repository-root rule, and returns no `spacesYAMLImported`, which would report a project it
/// created as a failure. A status read that fails is not permission either. The local daemon needs no such
/// read: `TerminalService.sendProfileCommand` refuses a wire-incompatible daemon before the command goes out.
func createProject(
    _ source: TerminalServiceProjectCreateSource, onDeviceNamed deviceName: String, daemonStatus: () throws -> TerminalServiceDaemonStatus,
    create: (_ projectDir: String?, _ gitURL: String?) throws -> SpacesDeviceAPIResponse
) throws -> CreatedProjectReport {
    let verdict = SpacesWireCompatibility.evaluate(daemonStatus: try daemonStatus())
    if let blocked = DaemonCompatibilityCopy.actionBlockedBody(deviceName: deviceName, verdict: verdict) {
        throw DeviceWireIncompatibleError(message: "Project not created. \(blocked)")
    }
    let response: SpacesDeviceAPIResponse
    switch source {
    case .dir(let dir): response = try create(dir, nil)
    case .gitURL(let url): response = try create(nil, url)
    }
    return try CreatedProjectReport(deviceResponse: response)
}

/// Whether a project folder can be sent to a daemon as it is. The daemon resolves the folder on its own
/// machine and expands a leading `~` against its own home, so only an absolute path or one starting with
/// `~` or `~/` means the same folder there as it does to the caller (the daemon does not expand `~user`).
func isDaemonResolvableProjectDirectory(_ dir: String) -> Bool { dir.hasPrefix("/") || dir == "~" || dir.hasPrefix("~/") }

/// The local CLI resolves a relative `--dir` against the shell's working directory before sending it,
/// since the daemon would otherwise resolve it against its own.
func localProjectDirectory(_ dir: String, currentDirectory: String) -> String {
    guard !isDaemonResolvableProjectDirectory(dir) else { return dir }
    return URL(fileURLWithPath: dir, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)).standardizedFileURL.path
}
