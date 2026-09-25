import Foundation
import spacesdevicecore

extension WorkspaceOrchestrator {
    /// Brings this daemon's single home project into existence and returns it, or returns nil when the
    /// project already registered at the home path is one this daemon must leave alone.
    ///
    /// The home project is where a terminal that belongs to no project lives. Every daemon owns exactly
    /// one, rooted at the account's home directory, so the row is there on every device without the user
    /// adding anything. This runs on every daemon start and is idempotent: the second and later calls
    /// resolve the same record and write nothing unless a field actually differs.
    ///
    /// The record is stored as a non-git project (`isGitRepo == false`) even when the home directory is a
    /// git repository, which is what makes every existing git/non-git gate in the daemon and the clients
    /// treat it as a plain directory: the discovery scan skips it, no branch or directory-name edit
    /// applies to it, and it owns exactly one workspace. The kind, not the directory, is the identity,
    /// because other projects are allowed to live under the home directory.
    ///
    /// Call this off the main actor. Adoption ends the processes the adopted project left running, which
    /// reaches the built-in session terminator and through it the terminal engine actor's synchronous
    /// bridge; that bridge traps on the main thread rather than throwing (the one-way rule). Adoption also
    /// removes the persisted row of any browser window the project's configuration left tracked, since the
    /// home row has no settings surface to show or reopen it from.
    ///
    /// `homeDirectory` has no default: the caller must resolve it from this daemon's own profile
    /// (`SpacesProfile.current().homeDirectoryURL`, read at the `SpacesdMain.ensureHomeProject` call
    /// site), never from `NSHomeDirectory()`. `NSHomeDirectory()` ignores an overridden `HOME`, so a
    /// daemon running under a HOME-isolated profile (a test or e2e harness) would otherwise report the
    /// real account's home as this device's Home row and launch terminals there instead of inside the
    /// isolated profile it is actually serving.
    @discardableResult public func ensureHomeProject(homeDirectory: String) throws -> ProjectRecord? {
        let dir = normalizePath(homeDirectory)
        // A project the user added at the home path by hand is adopted rather than left beside a second
        // home project: `projects.dir` is UNIQUE, so there is no room for both, and the hand-added one is
        // the same place with the same terminals in it. Adoption keeps the record's id, so the terminals
        // already recorded against its workspace stay where they are. Everything else the adopted record
        // held that a home project is not allowed to have (its configuration, its workspaces' settings, the
        // configured processes it left running, the browser window rows a configured browser session left
        // tracked, its setup state, any note, and any review-comment draft) is cleared here, because a home
        // project supports terminals and nothing else: no settings dialog can show that configuration
        // again, no client shows notes UI for it, no client shows an Editor for it to review a comment
        // through, and leaving any of it would keep launching processes and offering services, browser
        // sessions, or an unreachable note or draft from a row with no Start, Stop, or settings of its own.
        //
        // `store.homeProject()` wins over `store.project(dir: dir)` whenever both exist, which is what
        // this device already has a home project. Accepted risk: if the resolved home directory changes
        // (an account rename, or a profile restored under another home path) to a directory some standard
        // project is already registered at, the home record below still rebuilds against `dir`, and the
        // `store.upsert(project:)` a few lines down fails on the `projects.dir` UNIQUE constraint because
        // that directory is taken. `ensureHomeProject` throws, `SpacesdMain.ensureHomeProject` logs it and
        // moves on, and the Home row stays rooted at its previous directory until a later start finds
        // `dir` free, which happens once the user removes the standard project sitting on it. No
        // reconciliation runs here: a home directory landing on an already-registered project is rare
        // enough, and self-correcting enough once that project is gone, that adding one is not worth the
        // complexity.
        let existing = try store.homeProject() ?? store.project(dir: dir)
        if let existing, try homeProjectAdoptionIsRefused(existing) { return nil }
        // Ahead of every write, because ending a process is the one step here that leaves the database to
        // reach a live terminal session: it goes through the daemon's session terminator, and a failure
        // there must not leave a record already rewritten as the home project still owning the process
        // rows it can offer no Stop, Restart, or settings for. Ending first means the row a client reads
        // flips to the home project only once the processes and browser windows it carried are gone, and a
        // start that failed part-way through finds the same ordinary project again and repeats the whole
        // ensure.
        if let existing { try endAdoptedProjectRuntime(projectID: existing.id) }
        let record = homeProjectRecord(from: existing, dir: dir)
        if homeProjectNeedsWrite(existing: existing, target: record) { try store.upsert(project: record) }
        try ensureDefaultWorkspace(for: record)
        try syncHomeWorkspaceDir(project: record)
        try moveAdoptedHiddenFlagToWorkspace(from: existing, project: record)
        try clearHomeWorkspaceState(project: record)
        return record
    }

    /// Whether a project already registered at the home path has to be left exactly as it is, logged once
    /// when it does.
    ///
    /// A home project is stored non-git, and a non-git project is one row with one workspace everywhere:
    /// the lifecycle and editor gates refuse its workspace, the Workspaces dialog's non-git branch lists
    /// no children, and every surface names it `~`. Adopting a project that owns more than one workspace
    /// would therefore strand each of its workspaces but the default: still on disk, still in the
    /// database, and reachable from nothing. The device goes without a home project instead, until the
    /// user deletes the extra workspaces and the daemon starts again. Every surface that shows the home
    /// row reads the kind off the projects it is handed, so its absence is one row missing rather than a
    /// case anything has to handle.
    ///
    /// An automation targeting the project's workspace refuses adoption for the same reason: `~` is not a
    /// valid automation target (`AutomationService.validateWorkspaceTarget` refuses one), so adopting a
    /// project that already has automations would leave behind exactly the rows that rule exists to prevent.
    /// The automations are left where the user can still see and delete them, and the next daemon start
    /// adopts the project once they are gone.
    ///
    /// Only a project the user added is tested. A record that is already the home project owns exactly
    /// one workspace, since nothing creates a second one under it.
    private func homeProjectAdoptionIsRefused(_ existing: ProjectRecord) throws -> Bool {
        guard existing.kind != .home else { return false }
        let workspaces = try store.workspaces(projectID: existing.id)
        if workspaces.count > 1 {
            Self.writeStandardError(
                "spaces: project '\(existing.name)' at \(existing.dir) owns \(workspaces.count) workspaces; "
                    + "leaving it as it is and creating no home project\n")
            return true
        }
        var automationIDs: [String] = []
        for workspace in workspaces { automationIDs.append(contentsOf: try store.automationIDs(workspaceID: workspace.id)) }
        guard !automationIDs.isEmpty else { return false }
        Self.writeStandardError(
            "spaces: project '\(existing.name)' at \(existing.dir) is the target of an automation; "
                + "leaving it as it is and creating no home project\n")
        return true
    }

    /// The home project's target shape: `existing`'s identity when there is one to adopt, a fresh id when
    /// there is not, and in both cases the fixed name, the home kind, the non-git shape that kind implies,
    /// and no configuration at all.
    ///
    /// `isHidden` is always false: the home row's visibility has one authority, its workspace's own
    /// flag, which is the one the Workspaces dialog can clear (see `WorkspaceVisibilityTree.Toggle`), so
    /// the project record never carries a hidden flag of its own to disagree with it. An adopted
    /// project's own flag, or a project-level flag a home record still carries from before
    /// `updateProjectHidden` refused one, is moved onto the workspace instead of kept here (see
    /// `moveAdoptedHiddenFlagToWorkspace`).
    private func homeProjectRecord(from existing: ProjectRecord?, dir: String) -> ProjectRecord {
        ProjectRecord(
            id: existing?.id ?? UUID().uuidString, name: ProjectKind.homeProjectName, dir: dir, isGitRepo: false, defaultBranch: nil, kind: .home,
            isHidden: false)
    }

    /// Keeps the home workspace's `dir` in step with the project's after `ensureDefaultWorkspace` has
    /// already left the workspace alone because it exists.
    ///
    /// The project row is rewritten above whenever the home directory moves (an account rename, or a
    /// profile restored under another home path), but `ensureDefaultWorkspace` only mints a workspace when
    /// there is none yet; on every later start it finds the existing one and returns without touching it.
    /// Without this step the home project's single workspace would keep pointing at the old path forever.
    /// A home project owns exactly one workspace, so there is nothing to disambiguate here.
    private func syncHomeWorkspaceDir(project: ProjectRecord) throws {
        guard let workspace = try store.workspaces(projectID: project.id).first, workspace.dir != project.dir else { return }
        try store.upsert(
            workspace: WorkspaceRecord(
                id: workspace.id, projectID: workspace.projectID, dir: project.dir, dirname: workspace.dirname, branch: workspace.branch,
                baseBranch: workspace.baseBranch, isDefault: workspace.isDefault, isHidden: workspace.isHidden, isRunning: workspace.isRunning,
                lastLaunchedAt: workspace.lastLaunchedAt, notes: workspace.notes))
    }

    /// Moves a project-level hidden flag onto the workspace that stands in for it, so the row's
    /// visibility always has one authority afterward: the workspace flag the Workspaces dialog can clear.
    ///
    /// Two callers land here, both because the home project reads as a non-git project on every surface,
    /// and a non-git row's visibility checkbox drives its single workspace's flag rather than the
    /// project's:
    /// - Adoption hands over a standard project whose own hidden flag would otherwise take the row out of
    ///   every list with no control anywhere that could bring it back, once it becomes the home project
    ///   (`existing.kind != .home`).
    /// - An already-home record can itself carry a project-level `isHidden == true` left over from before
    ///   `updateProjectHidden` refused a project-level hide for the home kind. `homeProjectRecord` always
    ///   writes the project's own flag back to false, so this only has to move the flag onto the
    ///   workspace, never clear it: a start that finds the flag already clear reads `existing.isHidden`
    ///   false and writes nothing.
    ///
    /// The loop runs once: adoption is refused for a project that owns more than one workspace, and a
    /// home project owns exactly one.
    private func moveAdoptedHiddenFlagToWorkspace(from existing: ProjectRecord?, project: ProjectRecord) throws {
        guard let existing, existing.isHidden else { return }
        for workspace in try store.workspaces(projectID: project.id) { try updateWorkspaceHidden(workspaceID: workspace.id, isHidden: true) }
    }

    /// Whether the stored record differs from the shape `ensureHomeProject` owns. Only the fields that
    /// method sets are compared, the cleared configuration among them: a daemon start that finds them
    /// already right writes nothing.
    private func homeProjectNeedsWrite(existing: ProjectRecord?, target: ProjectRecord) -> Bool {
        guard let existing else { return true }
        return existing.name != target.name || existing.dir != target.dir || existing.isGitRepo != target.isGitRepo
            || existing.defaultBranch != target.defaultBranch || existing.kind != target.kind || existing.isHidden != target.isHidden
            || projectCarriesConfiguration(existing)
    }

    /// Whether a record still carries any of the configuration surface a home project does not have.
    private func projectCarriesConfiguration(_ project: ProjectRecord) -> Bool {
        project.setupScript != nil || project.stopScript != nil || !project.ports.isEmpty || !project.processes.isEmpty
            || !project.browserSessions.isEmpty
    }

    /// Brings every workspace under the home project to the shape a home workspace has, which is what
    /// adopting a configured project at the home path leaves undone: no settings, no setup state, no note,
    /// no review-comment drafts, and no stale `isRunning` flag. The process and browser-window runtime is
    /// ended before any of this, in `endAdoptedProjectRuntime`.
    ///
    /// The five steps are separate because they own separate records, and each one is its own idempotent
    /// check: every start after the one that adopted the project finds all five already clean and writes
    /// nothing. The loop runs once, since a home project owns exactly one workspace.
    private func clearHomeWorkspaceState(project: ProjectRecord) throws {
        for workspace in try store.workspaces(projectID: project.id) {
            try clearHomeWorkspaceSettings(workspaceID: workspace.id)
            try clearHomeWorkspaceSetupState(workspaceID: workspace.id)
            try clearHomeWorkspaceNotes(workspace: workspace)
            try clearHomeWorkspaceReviewComments(workspaceID: workspace.id)
            // An adopted project launched with no `running_processes` rows and no persisted browser window
            // (an empty configuration is enough) never reaches `stopRunningProcess` or the browser-row
            // delete in `endAdoptedProjectRuntime`, the chokepoint that otherwise reconciles `isRunning`
            // once those rows are gone. Without this, such a workspace keeps reading Running with nothing
            // tracked, and Start, Stop, and Restart stay refused on it forever, because
            // `assertWorkspaceHasLifecycle` refuses all three for a home workspace regardless of the flag.
            // Gated on the flag already being set: the write inside
            // `clearWorkspaceRunningIfNoTrackedRuntimeIndicators` is unconditional once it decides to run,
            // so calling it on every ensure (most of which find nothing to reconcile) would trip the "a
            // start that finds everything in shape writes nothing" contract every other step here keeps.
            if workspace.isRunning { try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspace.id) }
        }
    }

    /// Ends the configured processes and browser windows a project being adopted left behind, and removes
    /// their rows.
    ///
    /// Every configured process goes through `stopWorkspaceProcess`, the same chokepoint the sidebar's
    /// process Stop drives, so a live process's terminal session is ended the one way the product ends one
    /// and its window and `running_processes` rows go with it. That stop reaches the daemon's built-in
    /// session terminator, which enters the terminal engine actor synchronously, so `ensureHomeProject` is
    /// driven off the main actor (see `SpacesdMain.ensureHomeProject`). The rows have to go because the
    /// templates they came from do not survive adoption: the overview builds a process row per
    /// `running_processes` row, so a surviving row would show the home row running, or having run, a
    /// process it offers no Stop, Restart, or settings for.
    ///
    /// A persisted browser window row is removed the same way, but by deleting its `runtime_targets` row
    /// directly rather than through a live-session stop: a browser tab is client-owned (the daemon never
    /// closes one on an ordinary workspace stop either, see `stopWorkspaceUnlocked`), so there is no
    /// session to terminate, only the record of the target the workspace was configured to open. Left in
    /// place, that row would count as a tracked runtime indicator forever (`hasTrackedRuntimeIndicators`),
    /// reading the home row as Running with no Stop or settings surface left to clear it. Only browser-role
    /// rows are removed here: a terminal window row can belong to a live ad hoc terminal that keeps running
    /// as a home terminal, and that row has to stay, keeping the workspace Running, until the terminal
    /// exits on its own.
    ///
    /// Reading the workspaces rather than taking one id keeps this callable before the project record is
    /// rewritten, which is where it has to run; a start that finds nothing recorded reads three tables and
    /// writes nothing.
    private func endAdoptedProjectRuntime(projectID: String) throws {
        for workspace in try store.workspaces(projectID: projectID) {
            for process in try store.runningProcesses(workspaceID: workspace.id) {
                try stopWorkspaceProcess(workspaceID: workspace.id, processID: process.id)
            }
            for window in try store.windows(workspaceID: workspace.id) where window.roleValue == .browser { try store.deleteWindow(id: window.id) }
        }
    }

    /// Empties the stored settings of a workspace under the home project.
    ///
    /// One rule rather than two: a home workspace has no settings, so nothing downstream has to decide
    /// whether to show or run the settings it holds. The write goes through the ordinary settings path so
    /// clearing the service definitions also releases the ports they held. A workspace that stores
    /// nothing is not written at all.
    private func clearHomeWorkspaceSettings(workspaceID: String) throws {
        guard try homeWorkspaceCarriesSettings(workspaceID: workspaceID) else { return }
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try updateWorkspaceSettingsUnlocked(workspaceID: workspaceID) { settings in
                settings.stopScript = nil
                settings.ports = []
                settings.processes = []
                settings.browserSessions = []
            }
        }
    }

    /// Reads the four settings tables directly rather than through `loadWorkspaceSettings`, whose seeding
    /// of a missing settings row would be a write on a start that has nothing to clear.
    private func homeWorkspaceCarriesSettings(workspaceID: String) throws -> Bool {
        if try store.workspaceStopScript(workspaceID: workspaceID) != nil { return true }
        if try !store.workspaceServiceDefinitions(workspaceID: workspaceID).isEmpty { return true }
        if try !store.workspaceProcesses(workspaceID: workspaceID).isEmpty { return true }
        return try !store.workspaceBrowserSessions(workspaceID: workspaceID).isEmpty
    }

    /// Resets the setup state an adopted workspace persisted to the shape a workspace with no setup
    /// script has, through the store write every other setup transition uses.
    ///
    /// The setup script goes with the rest of the configuration, so the state left over from it describes
    /// a run that can never happen again: a `pending`, `running`, or `failed` state keeps the overview
    /// reporting setup for the home workspace, which puts the Workspace Setup screen and its Retry over
    /// the terminals the home row exists for. A `succeeded` state's metadata is reset with it, so the
    /// stored row is the one a workspace that never had a setup script holds rather than a record of the
    /// adopted project's last run.
    private func clearHomeWorkspaceSetupState(workspaceID: String) throws {
        guard let state = try store.workspaceSetupState(workspaceID: workspaceID), homeWorkspaceCarriesSetupState(state) else { return }
        try store.setWorkspaceSetupState(workspaceID: workspaceID, status: .succeeded)
    }

    /// Whether a stored setup state differs from the one a workspace with no setup script holds: the
    /// `succeeded` status a missing row also reads as, and no error, timestamps, exit code, or log path.
    private func homeWorkspaceCarriesSetupState(_ state: WorkspaceSetupState) -> Bool {
        state.status != .succeeded || state.errorMessage != nil || state.startedAt != nil || state.finishedAt != nil || state.exitCode != nil
            || state.logPath != nil
    }

    /// Clears a note an adopted workspace already held, through the same store write the notes UI drives.
    ///
    /// `updateWorkspaceNotes` refuses a home workspace (`assertWorkspaceIsConfigurable`), and neither
    /// client shows notes UI for the home row, so a note left over from adoption would stay persisted and
    /// go out in every overview with no way to view or remove it. This bypasses that refusal the same way
    /// `clearHomeWorkspaceSettings` bypasses it for settings: the refusal exists to keep a client from
    /// writing new configuration, not to keep adoption from clearing what an ordinary project already left
    /// behind.
    private func clearHomeWorkspaceNotes(workspace: WorkspaceRecord) throws {
        guard workspace.notes != nil else { return }
        try withWorkspaceLifecycleLock(workspaceID: workspace.id) { try store.updateWorkspaceNotes(id: workspace.id, notes: nil) }
    }

    /// Deletes the review-comment drafts an adopted workspace already held, through the store's
    /// workspace-scoped draft delete. A comment already sent stays: it is the workspace's record of what
    /// was actually sent, and adoption only clears the surface a home workspace cannot have, not that
    /// record.
    ///
    /// A home workspace has no Editor, so a draft left over from adoption could never be shown, edited, or
    /// sent again: every review-comment list, edit, delete, and send handler refuses a home workspace
    /// through `resolveEditableWorkspace`. Left in place, the row would sit in `workspace_review_comments`
    /// forever with no client able to reach it. The guard reads only the draft listing (the same one the
    /// code pane's card list uses), so a workspace with nothing outstanding to clear reads that one table
    /// and writes nothing.
    private func clearHomeWorkspaceReviewComments(workspaceID: String) throws {
        guard try !store.reviewCommentDrafts(workspaceID: workspaceID).isEmpty else { return }
        try store.deleteReviewCommentDrafts(workspaceID: workspaceID)
    }

    /// Refuses an operation on a project whose kind does not have it. The home project carries no
    /// configuration surface at all: no `spaces.yaml`, no setup or stop script, no services, no processes,
    /// and no browser sessions. Refusing at the daemon rather than only hiding the controls keeps a
    /// direct Device API call from writing configuration that no client can ever show or edit again.
    func assertProjectIsConfigurable(_ project: ProjectRecord) throws {
        guard project.kind != .home else { throw WorkspaceError.invalidArgument(message: "The home project has no configuration.") }
    }

    /// Refuses a workspace-settings or notes write for a home project's workspace, with the same refusal
    /// the project's own configuration carries: the workspace is the other half of the surface a home
    /// project does not have, and a settings or notes write reaching it would put back exactly what
    /// `ensureHomeProject` clears, or persist a note no client can ever show for the row.
    func assertWorkspaceIsConfigurable(workspaceID: String) throws {
        let (project, _) = try resolveWorkspace(id: workspaceID)
        try assertProjectIsConfigurable(project)
    }

    /// Refuses Start, Stop, and Restart for a home project's workspace.
    ///
    /// A home workspace has no lifecycle to drive: it has no configured runtime to launch, and it is
    /// marked running by whatever ad hoc terminal a user opens against it and stops again when the last
    /// one exits. A stop would therefore mean "kill the terminals living in the home row", which no
    /// client offers and nothing should reach by naming the workspace directly.
    func assertWorkspaceHasLifecycle(workspaceID: String) throws {
        let (project, _) = try resolveWorkspace(id: workspaceID)
        guard project.kind != .home else {
            throw WorkspaceError.invalidArgument(message: "The home project has no workspace lifecycle; open a terminal in it instead.")
        }
    }
}
