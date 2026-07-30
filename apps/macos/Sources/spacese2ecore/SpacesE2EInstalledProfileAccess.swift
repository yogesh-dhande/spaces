/// What one `spacese2e` command is allowed to do when the invocation targets the installed profile
/// (`~/.spaces`) — the profile a user's own app, daemon, and CLI serve.
///
/// The two permitting cases differ only in what they describe, not in what they allow: `readOnly` observes,
/// `reversible` changes something the sweep can put back. Both are stated rather than collapsed because the
/// distinction is the whole reason a command is in the permitted set at all, and it is what a new command's
/// classification has to be argued against.
public enum SpacesE2EInstalledProfileAccess: Equatable, Sendable {
    /// Observes only: reads state, reports it, and writes nothing to the profile.
    case readOnly

    /// Mutates only what a QA sweep can undo or re-do — runtime, window, and session state it created or can
    /// recreate. Never creates or removes a project, a workspace, or a paired device.
    case reversible

    /// Never allowed against the installed profile. `reason` is written for the person who typed the command
    /// and is quoted verbatim in the refusal.
    case refused(reason: String)

    /// Every `spacese2e` command's installed-profile classification, declared here and nowhere else.
    ///
    /// A command that is absent has no classification and is refused (see `SpacesE2EInstalledProfileSelection`),
    /// so the table fails closed: a command added later cannot join the permitted set by omission, and its
    /// author has to decide what it does to a live profile before it can reach one.
    ///
    /// Keys are top-level command names as ArgumentParser sees them. A command group is classified as a whole
    /// — its subcommands are not keys — so the group's entry has to hold for every subcommand it owns.
    public static let byCommandName: [String: SpacesE2EInstalledProfileAccess] = [
        // Read-only: the measurements a QA sweep of the installed build is built on.
        "dump-workspace": .readOnly,
        "dump-terminal-session-window-state": .readOnly,
        "focusable-window-names": .readOnly,
        "lookup-workspace": .readOnly,
        "mac-client-installation-id": .readOnly,
        "profile-app-owner": .readOnly,
        "profile-desktop-control-owner": .readOnly,
        "profile-show": .readOnly,
        "profile-socket-paths": .readOnly,
        "profile-wait-for-desktop-control": .readOnly,
        "record-screen": .readOnly,
        "render-update-text": .readOnly,
        "surface-snapshot": .readOnly,
        "terminal-service-state": .readOnly,

        // Reversible: terminal session and pane lifecycle. A session these start is one they can end, and
        // ending a session is what removes the abnormal-teardown distortion from a resource measurement.
        "start-workspace-terminal-session": .reversible,
        "terminate-terminal-session": .reversible,
        "open-workspace-terminal": .reversible,
        "close-terminal-session-window": .reversible,
        "focus-terminal-session-window": .reversible,
        "terminal-window-shortcut": .reversible,
        "terminal-service-control": .reversible,
        "clear-workspace-agent-windows": .reversible,

        // Reversible: workspace runtime. Stopping a workspace or a process is undone by starting it again;
        // neither removes the workspace, the project, or the process template.
        "stop-workspace": .reversible,
        "run-workspace-process": .reversible,
        "stop-workspace-process": .reversible,
        "restart-workspace-process": .reversible,
        "launch-workspace-agent": .reversible,

        // Reversible: workspace settings a sweep replaces to drive a launcher or a browser session, and
        // clears again afterwards. These REPLACE what one workspace has configured, so they are aimed at a
        // workspace the sweep is exercising rather than at one the user has set up for their own work.
        "set-workspace-agent-launchers": .reversible,
        "set-workspace-browser-session-urls": .reversible,

        // Reversible: focus, cycling, and window visibility. Nothing here is persisted state.
        "focus-workspace-window": .reversible,
        "cycle-workspace-window": .reversible,
        "focus-workspace-process": .reversible,
        "close-workspace-process-window": .reversible,
        "select-workspace-detail": .reversible,
        "show-main-window": .reversible,
        "hide-main-window": .reversible,

        // Reversible: desktop input against a window, which is how the rendered surface is exercised at all.
        "click-application-window": .reversible,
        "drag-application-window": .reversible,
        "scroll-application-window": .reversible,
        "type-application-window": .reversible,

        // Reversible: reports the daemon's Device API status, relaunching an idle daemon if one is not
        // answering — the same recovery the shipped CLI performs, and not a change to any profile state.
        "mobile-status": .reversible,

        // Refused: creates or removes projects and workspaces. Creation is irreversible on the installed
        // profile — nothing in the product removes a project or a workspace — so seeding is out of bounds
        // there, and that makes fixture teardown out of bounds with it.
        "seed-fixture": .refused(reason: "it registers projects and creates workspaces, which nothing can remove from the installed profile"),
        "register-project": .refused(reason: "it registers a project, and nothing removes a project from the installed profile"),
        "create-workspace": .refused(reason: "it creates a workspace and its worktree, and nothing removes a workspace from the installed profile"),
        "cleanup-fixtures": .refused(reason: "it removes projects, which must never happen to a profile a user relies on"),
        "stop-fixtures": .refused(reason: "it acts on every workspace under a directory prefix, which is a fixture-shaped sweep of a live profile"),
        "e2e": .refused(reason: "the E2E lanes seed their own projects and workspaces and tear them down again"),
        "record-mobile-demo": .refused(reason: "it records from seeded fixture workspaces, which the installed profile must not have"),

        // Refused: removes a workspace from the user's own view, or overwrites configuration the sweep has
        // no way to restore.
        "archive-workspace": .refused(reason: "archiving a workspace takes it out of the user's list and this tooling never puts it back"),
        "hide-workspace": .refused(reason: "hiding a workspace takes it out of the user's list and this tooling never puts it back"),
        "set-workspace-stop-script": .refused(reason: "it overwrites the workspace's configured stop script with no record of what was there"),
        "add-workspace-process": .refused(reason: "it writes a process template into workspace settings the user configured"),
        "remove-workspace-process": .refused(reason: "it deletes a process template from workspace settings the user configured"),

        // Refused: device pairing. A pairing is a durable trust relationship of the user's real profile, and
        // a QA sweep neither needs to add one nor can take one back.
        "open-device-pairing-window": .refused(reason: "it opens a pairing window for the user's real profile and issues a pairing token"),
        "open-remote-device-pairing-window": .refused(reason: "it pairs a remote daemon with the user's real profile"),
        "pair-remote-device": .refused(reason: "it pairs a remote daemon with the user's real profile and stores its credentials"),
        "seed-paired-device": .refused(reason: "it writes a paired-device row and an auth token into the user's real client store"),

        // Refused: serves or reaches a profile over the Device API, where the request itself decides what
        // happens. A raw request channel cannot be classified by the command that carries it.
        "mobile-serve": .refused(reason: "it runs a second Device API server for the profile, which the installed daemon already serves"),
        "mobile-request": .refused(reason: "it carries an arbitrary Device API request, so what it does to a profile cannot be classified here"),
        "service-tunnel": .refused(reason: "it opens a tunnel through a paired device, which the installed profile's pairings are not for"),

        // Refused: acts on the machine's profile inventory rather than on a resolved profile, and `remove`
        // deletes a profile root outright.
        "profile": .refused(reason: "it inspects and deletes development profiles on a device, so a profile binding says nothing about it"),

        // Refused: puts a fabricated failure in front of the user in their own running app.
        "show-window-issue-modal": .refused(reason: "it shows a window-issue modal for a problem that did not happen"),
    ]
}
