import AppKit
import Foundation
import spacesterminalcore
import workspacecore

/// The content of the popover anchored to an automations-table row's Next run chip.
///
/// It states what the automation is set to do next, offers the manual trigger, and picks a one-time override
/// of the next occurrence: the automation fires once at the chosen instant, then its cron schedule resumes
/// (a manual automation simply gets that one scheduled run). The device call is left to
/// `AutomationsController` through `onSchedule`, which reports back the daemon's message on failure so this
/// view stays free of device and client concerns.
@MainActor final class AutomationNextRunPopover: NSViewController {
    /// The note shown in place of a usable picker for a switched-off automation. It matches the daemon's own
    /// rejection message, so the reason reads the same whether it is prevented here or refused there.
    static let disabledNote = "Enable the automation to schedule its next run."

    private let automation: TerminalServiceAutomationSummary
    private let timeZone: TimeZone
    /// The device's zone identifier when it differs from this Mac's, appended to the times this popover
    /// shows and reads so a cross-zone automation is never misread as local wall-clock time.
    private let zoneSuffix: String?
    private let onRunNow: () -> Void
    /// Submits the picked instant and returns the daemon's error message, or nil once it has landed.
    private let onSchedule: (Date) async -> String?

    private let dateField = NSTextField(string: "")
    private let hourField = NSTextField(string: "")
    private let minuteField = NSTextField(string: "")
    private let scheduleButton = NSButton()
    private let errorLabel = NSTextField(labelWithString: "")

    init(
        automation: TerminalServiceAutomationSummary, timeZone: TimeZone, zoneSuffix: String?, onRunNow: @escaping () -> Void,
        onSchedule: @escaping (Date) async -> String?
    ) {
        self.automation = automation
        self.timeZone = timeZone
        self.zoneSuffix = zoneSuffix
        self.onRunNow = onRunNow
        self.onSchedule = onSchedule
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override func loadView() {
        let title = NSTextField(labelWithString: automation.name)
        title.font = Typography.compactTitle
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail

        let summary = NSTextField(labelWithString: suffixed(AutomationsViewModel.nextRunSummaryLine(for: automation, timeZone: timeZone)))
        summary.font = Typography.metadata
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail

        let runNow = NSButton(title: "Run Now", target: self, action: #selector(runNowTapped))
        runNow.bezelStyle = .rounded
        runNow.controlSize = .small
        runNow.font = Typography.secondaryButtonLabel
        runNow.toolTip = "Run this automation now"

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let pickerTitle = NSTextField(labelWithString: suffixed("Next run at"))
        pickerTitle.font = Typography.metadataTitle
        pickerTitle.textColor = Theme.mutedSecondary

        seedPickerFields()
        configureField(dateField, width: 104, alignment: .left, placeholder: "YYYY-MM-DD")
        configureField(hourField, width: 52, alignment: .right, placeholder: "0")
        configureField(minuteField, width: 52, alignment: .right, placeholder: "0")
        let colon = NSTextField(labelWithString: ":")
        colon.font = Typography.body
        let pickerRow = NSStackView(views: [dateField, hourField, colon, minuteField, NSView()])
        pickerRow.orientation = .horizontal
        pickerRow.alignment = .centerY
        pickerRow.spacing = 6

        scheduleButton.title = "Schedule"
        scheduleButton.target = self
        scheduleButton.action = #selector(scheduleTapped)
        scheduleButton.bezelStyle = .rounded
        scheduleButton.controlSize = .small
        scheduleButton.font = Typography.primaryButtonLabel
        scheduleButton.keyEquivalent = "\r"
        let scheduleRow = NSStackView(views: [NSView(), scheduleButton])
        scheduleRow.orientation = .horizontal
        scheduleRow.alignment = .centerY

        errorLabel.font = Typography.metadata
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true

        // A switched-off automation keeps its manual trigger and its stated schedule, but the picker is inert:
        // the daemon refuses to schedule a run for an automation that cannot fire, so the note says why here
        // rather than letting the request go out to be rejected.
        var rows: [NSView] = [title, summary, runNow, divider]
        if !automation.enabled {
            let note = NSTextField(labelWithString: Self.disabledNote)
            note.font = Typography.metadata
            note.textColor = .secondaryLabelColor
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 2
            rows.append(note)
            for control in [dateField, hourField, minuteField, scheduleButton] { control.isEnabled = false }
        }
        rows.append(contentsOf: [pickerTitle, pickerRow, scheduleRow, errorLabel])

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12), stack.widthAnchor.constraint(equalToConstant: 260),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor), scheduleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pickerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = contentView
    }

    /// Shows a failure inline. Called by the controller with the daemon's own message.
    func showScheduleError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        scheduleButton.isEnabled = true
    }

    // MARK: - Fields

    /// Opens on the instant the automation is already set to fire at, so nudging an existing schedule means
    /// editing one field. With nothing scheduled it opens an hour out, same as the iOS sheet: seeding "now"
    /// truncates to the start of the current minute, which the future-time validation would always refuse.
    private func seedPickerFields() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let seed = automation.nextFireTime.flatMap(TerminalSessionTimestamp.date(from:)) ?? Date().addingTimeInterval(3600)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: seed)
        dateField.stringValue = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
        hourField.stringValue = "\(parts.hour ?? 0)"
        minuteField.stringValue = "\(parts.minute ?? 0)"
    }

    private func configureField(_ field: NSTextField, width: CGFloat, alignment: NSTextAlignment, placeholder: String) {
        field.font = Typography.body
        field.placeholderString = placeholder
        field.alignment = alignment
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func suffixed(_ text: String) -> String {
        guard let zoneSuffix else { return text }
        return "\(text) (\(zoneSuffix))"
    }

    // MARK: - Actions

    @objc private func runNowTapped() { onRunNow() }

    @objc private func scheduleTapped() {
        guard let hour = AutomationScheduleFieldValidation.integer(hourField.stringValue, range: 0...23),
            let minute = AutomationScheduleFieldValidation.integer(minuteField.stringValue, range: 0...59),
            let instant = AutomationsViewModel.parseNextRunInstant(dateText: dateField.stringValue, hour: hour, minute: minute, timeZone: timeZone)
        else {
            showScheduleError("Enter a date as YYYY-MM-DD and a time as hour (0-23) and minute (0-59).")
            return
        }
        guard AutomationsViewModel.nextRunInstantIsAcceptable(instant, now: Date()) else {
            showScheduleError("Pick a time in the future.")
            return
        }
        errorLabel.isHidden = true
        // Blocked for the round trip so a second click cannot send a second schedule request; a failure
        // re-enables it through `showScheduleError`, and success closes the popover.
        scheduleButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            if let message = await onSchedule(instant) { showScheduleError(message) }
        }
    }
}
