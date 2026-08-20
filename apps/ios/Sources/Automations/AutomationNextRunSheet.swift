import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// The next-run sheet, opened from the "Next run" chip on `AutomationDetailView`. It carries both ways
/// to make an automation run: Run Now, the explicit manual trigger, and a picker that sets a one-time
/// next run. Scheduling a time overrides only the next occurrence: once it fires, a cron automation
/// resumes its own schedule and a manual automation goes back to firing only when asked.
///
/// A disabled automation can still be run from here (Run Now is a manual trigger and does not consult the
/// schedule), but the daemon refuses to schedule one, so the picker and Schedule button are inert with a
/// note saying what to do about it rather than letting the user post a request that can only fail.
struct AutomationNextRunSheet: View {
    @Bindable var model: SpacesMobileAppModel
    let automation: TerminalServiceAutomationSummary
    /// Runs after Run Now and after an accepted schedule, so the detail screen refetches its run history.
    let onMutated: () async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var nextRun: Date
    @State private var errorMessage: String?

    init(model: SpacesMobileAppModel, automation: TerminalServiceAutomationSummary, onMutated: @escaping () async -> Void) {
        self.model = model
        self.automation = automation
        self.onMutated = onMutated
        // Opens on the instant the automation is already set to fire at, same as the Mac popover, so
        // nudging an existing schedule means editing one component. With nothing scheduled it opens an
        // hour out rather than on "now", which the future-time validation would immediately refuse. The
        // fallback is floored to the minute: the picker shows only hour and minute, and it edits only
        // those components, so seconds carried in the seed would silently persist and make the run fire
        // after the instant the picker displayed.
        let hourOut = Date().addingTimeInterval(3600)
        let flooredHourOut = Date(timeIntervalSince1970: (hourOut.timeIntervalSince1970 / 60).rounded(.down) * 60)
        _nextRun = State(initialValue: automation.nextFireTime.flatMap(TerminalSessionTimestamp.date(from:)) ?? flooredHourOut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(automation.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(SpacesMobileAutomations.nextRunSummary(automation)).font(.system(size: 13)).foregroundStyle(Theme.mutedSecondary)
                    .accessibilityIdentifier("automations.nextRun.summary")
            }

            Button {
                Task {
                    await model.triggerAutomation(id: automation.id)
                    await onMutated()
                    dismiss()
                }
            } label: {
                Text("Run Now")
            }.buttonStyle(BrandPrimaryButtonStyle()).disabled(model.isMutating).accessibilityIdentifier("automations.nextRun.runNow")

            VStack(alignment: .leading, spacing: 6) {
                // Shown in this viewer's own time zone, unlike the Mac popover, which uses the device's:
                // on a phone the user reads and thinks in their local wall clock, and the instant sent to
                // the daemon is absolute either way, so nothing is lost in translation.
                DatePicker("Next run at", selection: $nextRun, displayedComponents: [.date, .hourAndMinute]).datePickerStyle(.compact).font(
                    .system(size: 13, weight: .medium)
                ).foregroundStyle(Theme.text).disabled(isScheduleDisabled).accessibilityIdentifier("automations.nextRun.picker")
                if !automation.enabled {
                    Text("Enable the automation to schedule its next run.").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary)
                }
            }

            Button {
                schedule()
            } label: {
                Text("Schedule")
            }.buttonStyle(BrandPrimaryButtonStyle()).disabled(isScheduleDisabled).accessibilityIdentifier("automations.nextRun.schedule")

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(
                    "automations.nextRun.error")
            }

            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.bg).presentationDetents([.medium])
            .presentationBackground(Theme.bg).tint(Theme.accent).accessibilityIdentifier("automations.nextRun.sheet")
    }

    private var isScheduleDisabled: Bool { !automation.enabled || model.isMutating }

    private func schedule() {
        if let rejection = SpacesMobileAutomations.nextRunValidationMessage(for: nextRun) {
            errorMessage = rejection
            return
        }
        Task {
            errorMessage = await model.setAutomationNextRun(id: automation.id, nextRunTime: nextRun)
            guard errorMessage == nil else { return }
            await onMutated()
            dismiss()
        }
    }
}
