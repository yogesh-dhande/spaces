import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Per-automation detail, pushed by tapping a row in `AutomationsListView`: the automation's schedule,
/// target workspace, and command up top, an explicit "Run Now" button as the only manual trigger, and
/// this automation's own run history below. Run Now stays enabled while a run is already in flight — the
/// daemon's concurrency policy decides whether the new attempt runs, queues, or is skipped, and that
/// outcome shows up as a new row in the runs list once the overview refreshes, mirroring how
/// `SpacesMobileAppModel.triggerAutomation` already surfaces the outcome elsewhere with no separate
/// confirmation.
struct AutomationDetailView: View {
    @Bindable var model: SpacesMobileAppModel
    let automationID: String
    /// Retained run history fetched directly from the daemon (nil until first fetched), reconciled with
    /// the live overview window via `SpacesMobileAutomations.mergedRunRows` — see that function's doc
    /// comment for why the overview wins on conflict. Mirrors the machinery the per-automation
    /// `AutomationRunsView` mode used before this screen replaced it.
    @State private var fetchedRuns: [TerminalServiceAutomationRunSummary]?

    private var automation: TerminalServiceAutomationSummary? {
        model.automationRows.first(where: { $0.automation.id == automationID })?.automation
    }

    private var runs: [SpacesMobileAutomationRunRow] {
        SpacesMobileAutomations.mergedRunRows(
            overviewRuns: model.overview?.automationRuns ?? [], historyRuns: fetchedRuns ?? [], automationID: automationID)
    }

    var body: some View {
        content.navigationTitle(automation?.name ?? "Automation").tint(Theme.accent).overviewPolling(
            model: model, tab: .automations, activeDetailRouteID: nil
        ).task { await loadRuns() }
    }

    /// Fetches this automation's run history through the daemon's retained-runs endpoint, supplying the
    /// older tail the overview window doesn't carry.
    private func loadRuns() async {
        if let runs = await model.fetchAutomationRuns(automationID: automationID) { fetchedRuns = runs }
    }

    @ViewBuilder private var content: some View {
        if let automation {
            ScrollView {
                LazyVStack(spacing: 0) {
                    runNowButton(automation)
                    factsSection(automation)
                    runsSection
                }.padding(.vertical, 12)
            }.scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea()).refreshable {
                await model.refresh()
                await loadRuns()
            }
        } else {
            // Reachable if the automation is deleted on the Mac while this screen is open on iOS: the
            // overview refresh that drops it from `model.automationRows` lands while the user is still
            // looking at its detail screen.
            ContentUnavailableView {
                Label("Automation Removed", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("This automation no longer exists on \(model.activeDeviceName ?? "this device").")
            }.background(Theme.bg.ignoresSafeArea())
        }
    }

    private func runNowButton(_ automation: TerminalServiceAutomationSummary) -> some View {
        Button {
            Task {
                await model.triggerAutomation(id: automation.id)
                await loadRuns()
            }
        } label: { Text("Run Now") }.buttonStyle(BrandPrimaryButtonStyle()).disabled(model.isMutating).padding(.horizontal, 20).padding(
            .bottom, 14
        ).accessibilityIdentifier("automations.detail.runNow")
    }

    private func factsSection(_ automation: TerminalServiceAutomationSummary) -> some View {
        VStack(spacing: 0) {
            HeaderBand {
                Text("Automation").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                factRow(label: "Schedule", value: SpacesMobileAutomations.triggerSummary(automation))
                if let nextFire = SpacesMobileAutomations.nextFireDescription(automation) { factRow(label: "Next run", value: nextFire) }
                if let workspaceName = SpacesMobileAutomations.workspaceName(for: automation, in: model.overview?.workspaces ?? []) {
                    factRow(label: "Workspace", value: workspaceName)
                }
                factRow(label: "Enabled", value: automation.enabled ? "Yes" : "No")
                commandBlock(automation)
            }.padding(.top, 4)
        }.padding(.bottom, 14)
    }

    private func factRow(label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).lineLimit(1).truncationMode(.middle)
        }.padding(.vertical, 8).padding(.horizontal, 20)
    }

    /// The automation's full command (an agent automation's prompt, a script automation's script), unlike
    /// the list row's single-line `SpacesMobileAutomations.excerpt`. Deliberately unclamped: the screen
    /// scrolls, and hiding part of the command would misrepresent what the automation does.
    private func commandBlock(_ automation: TerminalServiceAutomationSummary) -> some View {
        let command = automation.kind == "agent" ? (automation.agentPrompt ?? "") : automation.script
        return Text(command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).frame(
            maxWidth: .infinity, alignment: .leading
        ).padding(10).background(Theme.surface2).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(.horizontal, 20).padding(
            .top, 4)
    }

    @ViewBuilder private var runsSection: some View {
        VStack(spacing: 0) {
            HeaderBand {
                Text("Recent Runs").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            if runs.isEmpty {
                Text("Runs appear here once the automation fires.").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(.horizontal, 20).padding(.top, 8)
            } else {
                AutomationRunRowsList(model: model, rows: runs, title: { SpacesMobileAutomations.statusTitle($0) }, onMutated: { await loadRuns() })
                    .padding(.top, 4)
            }
        }
    }
}
