import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Shared run-row rendering for the two run-history surfaces (`AutomationRunsView`'s global "Recent
/// Runs" list and `AutomationDetailView`'s per-automation runs section): the row itself (status dot,
/// title, detail line, Cancel/End Agents trailing action, attributed-agents chips) plus the two
/// confirmation dialogs that gate those trailing actions. `title` is parameterized because the two
/// screens want a different row title for the same run: the global screen shows the automation name
/// (many automations share one list), the detail screen shows the run's outcome (the automation name is
/// already the screen's own navigation title, so repeating it on every row would be redundant).
struct AutomationRunRowsList: View {
    @Bindable var model: SpacesMobileAppModel
    let rows: [SpacesMobileAutomationRunRow]
    let title: (TerminalServiceAutomationRunSummary) -> String
    /// Called after a Cancel or End Agents mutation completes, so the caller can re-fetch whatever run
    /// history it separately retains (the per-automation retained fetch on the detail screen; a no-op for
    /// the overview-only global screen).
    let onMutated: () async -> Void
    /// Called when a run row or an attributed-agent chip resolves a session to open (see
    /// `SpacesMobileAutomations.runSession`/`agentSession`).
    let onOpenSession: (SpacesDeviceTerminalSessionSummary) -> Void
    @State private var pendingCancelRunID: String?
    @State private var pendingEndAgentsRunID: String?

    var body: some View {
        // A VStack, not a Group: modifiers on a Group apply to each child, which would attach a copy of
        // both confirmation dialogs to every row while they all share one isPresented binding. The VStack
        // gives the dialogs a single attachment point. Laziness lost against the surrounding LazyVStack is
        // irrelevant at run-history sizes (overview window is 50, retention caps history at 100).
        VStack(spacing: 0) { ForEach(rows) { row in runRow(row) } }.confirmationDialog(
            "Cancel this run?", isPresented: cancelDialogBinding, titleVisibility: .visible
        ) {
            Button("Cancel Run", role: .destructive) {
                guard let pendingCancelRunID else { return }
                Task {
                    await model.cancelAutomationRun(runID: pendingCancelRunID)
                    await onMutated()
                }
            }
            Button("Keep Running", role: .cancel) {}
        }.confirmationDialog("End this run's agents?", isPresented: endAgentsDialogBinding, titleVisibility: .visible) {
            Button("End Agents", role: .destructive) {
                guard let pendingEndAgentsRunID else { return }
                Task {
                    await model.endAutomationAgents(runID: pendingEndAgentsRunID)
                    await onMutated()
                }
            }
            Button("Keep Agents Running", role: .cancel) {}
        }
    }

    private var cancelDialogBinding: Binding<Bool> { Binding(get: { pendingCancelRunID != nil }, set: { if !$0 { pendingCancelRunID = nil } }) }

    private var endAgentsDialogBinding: Binding<Bool> {
        Binding(get: { pendingEndAgentsRunID != nil }, set: { if !$0 { pendingEndAgentsRunID = nil } })
    }

    private func runRow(_ row: SpacesMobileAutomationRunRow) -> some View {
        let run = row.run
        var detailParts = [SpacesMobileAutomations.runTriggerLabel(run)]
        // Both read the shared 30-second label clock rather than `Date()`, so this text stays put across
        // the 2-second overview poll instead of jittering (#540) — see
        // `SpacesMobileAppModel.relativeTimeReference`. `startedDescription` clamps internally against a
        // reference that trails a just-started run; `durationDescription`'s own `max(0, ...)` already
        // covers the same case for the live-running duration it renders.
        if let started = SpacesMobileAutomations.startedDescription(run, relativeTo: model.relativeTimeReference) {
            detailParts.append(started)
        }
        if let duration = SpacesMobileAutomations.durationDescription(run, relativeTo: model.relativeTimeReference) {
            detailParts.append(duration)
        }
        if let exitCode = run.exitCode { detailParts.append("exit \(exitCode)") }
        if run.status == "skipped", let reason = run.skipReason { detailParts.append("skipped: \(SpacesMobileAutomations.skipReasonLabel(reason))") }

        let isNavigable = SpacesMobileAutomations.runIsNavigable(run)
        let band = BandRow(
            dotKind: StatusDot.Kind(automationRunStatus: run.status), tile: TypeIconTile(systemName: "clock.arrow.circlepath"),
            title: title(run), detail: detailParts.joined(separator: " · "), detailIsMonospaced: false
        ) {
            if row.isRunning {
                Button {
                    pendingCancelRunID = run.id
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("automations.run.cancel.\(run.id)")
            } else if SpacesMobileAutomations.endAgentsAvailable(run) {
                // A text label, not an icon: ending someone's agent is not an obvious action (see
                // AGENTS.md GUI rules), matching the Mac's own "End agents" button.
                Button {
                    pendingEndAgentsRunID = run.id
                } label: {
                    Text("End agents").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.red)
                }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("automations.run.endAgents.\(run.id)")
            }
            if isNavigable { RowChevron() }
        }

        return VStack(alignment: .leading, spacing: 0) {
            // Navigation is not a mutation, so the row stays tappable while model.isMutating is true (that
            // flag only gates the Cancel/End Agents buttons above, which are separate Button views nested
            // inside this one — SwiftUI hit-tests to the innermost matching button, so each keeps its own
            // tap independent of this row's).
            if isNavigable {
                Button {
                    guard let session = SpacesMobileAutomations.runSession(for: run, overview: model.overview) else { return }
                    onOpenSession(session)
                } label: { band }.buttonStyle(.plain)
            } else {
                band
            }
            if !run.attributedAgents.isEmpty { attributedAgentsRow(run.attributedAgents) }
        }.accessibilityIdentifier("automations.run.\(row.id)")
    }

    /// The run's attributed coding agents (its own spawned agent, plus any a script's command spawned),
    /// each as a compact dot-plus-title element. Indented to align under the row's title column and
    /// independently horizontally scrollable so several agents never wrap or clip the row. A chip opens
    /// that agent's own terminal session on tap; a chip whose session cannot be resolved (see
    /// `SpacesMobileAutomations.agentSession`) stays inert.
    private func attributedAgentsRow(_ agents: [TerminalServiceAutomationAgentSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { ForEach(agents, id: \.terminalSessionID) { agent in attributedAgentChip(agent) } }
        }.padding(.leading, 58).padding(.trailing, 20).padding(.bottom, 8)
    }

    private func attributedAgentChip(_ agent: TerminalServiceAutomationAgentSummary) -> some View {
        let chip = HStack(spacing: 5) {
            StatusDot(kind: StatusDot.Kind(agentStatus: agent.status, live: agent.live))
            Text(agent.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent").font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
        }
        return Button {
            guard let session = SpacesMobileAutomations.agentSession(for: agent, overview: model.overview) else { return }
            onOpenSession(session)
        } label: { chip }.buttonStyle(.plain)
    }
}
