import Testing
import spacesdevicecore

@testable import spacesui

/// `OpenPanePruning.referencedTerminalSessionIDs` is the keep-set both prune call sites pass as
/// `catalogSessionIDs`. It reads the daemon's published retention verdict
/// (`SpacesDeviceOverviewPayload.retainedTerminalSessionIDs`) directly rather than re-deriving it from
/// overview row surfaces, so the client and the daemon garbage collector cannot drift. These tests pin
/// that the helper surfaces exactly the published ids (parsing them defensively) and that the removal
/// case still closes. The daemon-side rule that populates the field is covered in
/// `SpacesDeviceOverviewBuilderTests`.
@Suite struct ReferencedTerminalSessionIDsTests {
    private func overview(retained: [String], sessions: [String] = []) -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(workspaces: [], sessions: sessions.map(sessionSummary(id:)), retainedTerminalSessionIDs: retained)
    }

    private func sessionSummary(id: String) -> SpacesDeviceTerminalSessionSummary {
        SpacesDeviceTerminalSessionSummary(
            id: id, title: "shell", workingDirectory: "/tmp/workspace", shell: "/bin/zsh", command: nil, state: .running, backend: .ghosttyEmbedded,
            lifetimePolicy: .persistent, servicePID: 1234, childPID: 5678, workspaceID: "workspace", workspaceTitle: "Workspace",
            projectID: "project", projectName: "Project", createdAt: "2026-07-20T00:00:00Z", updatedAt: "2026-07-20T00:00:01Z",
            isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: .init())
    }

    /// The regression: an ended ad hoc shell has left `sessions` but the daemon still retains it through
    /// its `runtime_targets` row, so it is in `retainedTerminalSessionIDs`. Its pane must stay open.
    @Test func keepSetIncludesRetainedSessionAbsentFromSessionsList() {
        let payload = overview(retained: ["sess-ended-shell"], sessions: [])

        let keepSet = OpenPanePruning.referencedTerminalSessionIDs(overview: payload)
        #expect(keepSet.contains("sess-ended-shell"))

        let toClose = OpenPanePruning.sessionsToClose(
            openPanes: [OpenPanePruning.OpenPane(deviceID: "local", sessionID: "sess-ended-shell")], deviceID: "local", catalogSessionIDs: keepSet)
        #expect(toClose.isEmpty)
    }

    /// The removal case must keep working: a pane whose session the daemon no longer retains is absent
    /// from the keep-set and still closes.
    @Test func keepSetExcludesSessionTheDaemonNoLongerRetains() {
        let payload = overview(retained: ["sess-live"], sessions: ["sess-live"])

        let keepSet = OpenPanePruning.referencedTerminalSessionIDs(overview: payload)
        #expect(!keepSet.contains("sess-removed"))

        let toClose = OpenPanePruning.sessionsToClose(
            openPanes: [OpenPanePruning.OpenPane(deviceID: "local", sessionID: "sess-removed")], deviceID: "local", catalogSessionIDs: keepSet)
        #expect(toClose == ["sess-removed"])
    }

    /// The helper surfaces every published id verbatim.
    @Test func keepSetSurfacesEveryPublishedID() {
        let payload = overview(retained: ["sess-a", "sess-b", "sess-c"])
        #expect(OpenPanePruning.referencedTerminalSessionIDs(overview: payload) == ["sess-a", "sess-b", "sess-c"])
    }

    /// A malformed (empty or whitespace) published id must not inject an empty string into the keep-set.
    @Test func keepSetDropsBlankPublishedIDs() {
        let payload = overview(retained: ["", "   ", "sess-real"])
        #expect(OpenPanePruning.referencedTerminalSessionIDs(overview: payload) == ["sess-real"])
    }

    /// The regression for the restoration paths: an ended ad hoc shell has left `sessions` but the
    /// daemon still retains it through its `runtime_targets` row. The restoration keep-set must keep it
    /// (matching live pruning) so relaunch does not silently drop a pane a live overview refresh keeps.
    @Test func restorationKeepSetKeepsRetainedSessionAbsentFromSessionsList() {
        let payload = overview(retained: ["sess-ended-shell"], sessions: [])
        #expect(OpenPanePruning.restorationKeepSet(overview: payload).contains("sess-ended-shell"))
    }

    /// A session the daemon no longer retains is absent from the restoration keep-set, so its persisted
    /// pane is pruned on relaunch exactly as live pruning would close it.
    @Test func restorationKeepSetExcludesSessionTheDaemonNoLongerRetains() {
        let payload = overview(retained: ["sess-live"], sessions: ["sess-live"])
        #expect(!OpenPanePruning.restorationKeepSet(overview: payload).contains("sess-removed"))
    }

    /// A nil overview (device not loaded) contributes nothing, so persisted rows stay pending rather
    /// than pruning against an empty catalog.
    @Test func restorationKeepSetForNilOverviewIsEmpty() { #expect(OpenPanePruning.restorationKeepSet(overview: nil).isEmpty) }

    /// The multi-overview keep-set unions each device's retained ids and skips nil overviews, so a
    /// global panel window spanning devices keeps every retained pane.
    @Test func restorationKeepSetUnionsOverviewsAndSkipsNil() {
        let first = overview(retained: ["sess-a", "sess-ended"], sessions: ["sess-a"])
        let second = overview(retained: ["sess-b"], sessions: ["sess-b"])
        let keepSet = OpenPanePruning.restorationKeepSet(overviews: [first, nil, second])
        #expect(keepSet == ["sess-a", "sess-ended", "sess-b"])
    }
}
