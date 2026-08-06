import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Owns the create/edit automation form window. `AppKitController` holds one instance; the unowned `host`
/// gives access to the shared form-window chrome and device services. A type toggle switches between an
/// **Agent** automation (spawn a coding agent in a workspace, seeded with a prompt — the default for a new
/// automation) and a **Script** automation (a shell script in a working directory); the shared name/device/
/// trigger/schedule/timeout/concurrency fields apply to both. The cron schedule builder serializes to a cron
/// string via `AutomationSchedulePreset` — the string is the only stored form — and shows a live next-3-runs
/// preview plus inline parse validation. The device is chosen only at create time; an automation lives on its
/// device, so edit fixes it.
@MainActor final class AutomationEditorController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    private enum CronMode: Int {
        case builder
        case advanced
    }

    private var window: NSWindow?
    /// nil for a create; the automation id being edited otherwise.
    private var editingAutomationID: String?
    private var deviceID: String = SpacesPairedDeviceRecord.localDeviceID
    private var isLocalDevice: Bool = true
    private var deviceInputs: [AutomationDeviceInput] = []

    /// The kind currently selected in the type toggle. A new automation defaults to `.agent` (the headline
    /// simplification — most users just want to spawn an agent with a prompt); editing opens on the stored kind.
    private var currentKind: AutomationKind = .agent
    /// The workspace choices for the selected device, recomputed whenever the form is (re)built.
    private var workspaceChoices: [AppKitController.AutomationWorkspaceChoice] = []
    /// The last script text this editor auto-generated as an Agent→Script prefill, so a later switch can tell a
    /// stale prefill (safe to replace) from script the user has since authored (never clobber).
    private var lastGeneratedScriptPrefill: String?

    // Live control references, valid while the window is open.
    private var nameField: NSTextField?
    private var devicePopUp: NSPopUpButton?
    private var kindSegmented: NSSegmentedControl?
    private var workspacePopUp: NSPopUpButton?
    private var agentCommandField: NSTextField?
    private var agentPromptTextView: NSTextView?
    private var scriptTextView: NSTextView?
    private var workingDirectoryField: NSTextField?
    private var triggerSegmented: NSSegmentedControl?
    private var cronModeSegmented: NSSegmentedControl?
    private var presetKindPopUp: NSPopUpButton?
    private var everyNPopUp: NSPopUpButton?
    private var hourlyMinuteField: NSTextField?
    private var dailyHourField: NSTextField?
    private var dailyMinuteField: NSTextField?
    private var weeklyDayCheckboxes: [NSButton] = []
    private var weeklyHourField: NSTextField?
    private var weeklyMinuteField: NSTextField?
    private var advancedCronField: NSTextField?
    private var timeoutField: NSTextField?
    private var concurrencyPopUp: NSPopUpButton?
    private var missedRunPopUp: NSPopUpButton?
    private var previewLabel: NSTextField?
    private var errorLabel: NSTextField?
    private var saveButton: NSButton?

    /// Guards against a double Save: the async create/update request has no synchronous completion, so a second
    /// click or Return press before the window closes would otherwise fire a second request with its own
    /// automation id, producing a duplicate. Set before the Task is spawned, cleared on error and on the next
    /// `present` — this controller instance is reused across opens, so a successful save (which closes the
    /// window without clearing the flag) must not leave the next editor session unsaveable.
    private var isSaving = false

    // Rows whose visibility depends on the type toggle.
    private var workspaceRow: NSView?
    private var agentCommandRow: NSView?
    private var agentPromptRow: NSView?
    private var scriptRow: NSView?
    private var workingDirectoryRow: NSView?

    // Rows whose visibility depends on trigger/mode/preset selection.
    private var cronSectionRows: [NSView] = []
    private var builderRows: [NSView] = []
    private var advancedRow: NSView?
    private var everyNRow: NSView?
    private var hourlyRow: NSView?
    private var dailyRow: NSView?
    private var weeklyRow: NSView?

    // MARK: - Presentation

    func presentCreate(inputs: [AutomationDeviceInput]) {
        editingAutomationID = nil
        deviceInputs = inputs
        // Default to the local device (or the first reachable device).
        let reachable = inputs.filter(\.isReachable)
        deviceID = reachable.first(where: \.isLocal)?.deviceID ?? reachable.first?.deviceID ?? SpacesPairedDeviceRecord.localDeviceID
        isLocalDevice = reachable.first(where: { $0.deviceID == deviceID })?.isLocal ?? true
        present(title: "New Automation", seed: nil)
    }

    func presentEdit(deviceID: String, automation: TerminalServiceAutomationSummary) {
        editingAutomationID = automation.id
        self.deviceID = deviceID
        deviceInputs = host.automationDeviceInputs()
        isLocalDevice = deviceInputs.first(where: { $0.deviceID == deviceID })?.isLocal ?? (deviceID == SpacesPairedDeviceRecord.localDeviceID)
        present(title: "Edit Automation", seed: automation)
    }

    private func present(title: String, seed: TerminalServiceAutomationSummary?) {
        isSaving = false
        // Preserve the edited automation's stored workspace even when it has since been hidden, so saving an
        // unrelated edit never retargets it to the first visible workspace. Preservation applies ONLY to a
        // fixed-device edit: in edit mode the device can't change, so the stored workspace always belongs to
        // this device. During creation the device CAN change (a rebuild carries the old device's workspace
        // id forward), so preserving it there would append the previous device's workspace as a raw-id choice
        // the new device's daemon doesn't have; instead the popup resets to the new device's first choice.
        let preservingWorkspaceID = editingAutomationID != nil ? seed?.workspaceID : nil
        workspaceChoices = host.automationWorkspaceChoices(deviceID: deviceID, preservingWorkspaceID: preservingWorkspaceID)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        addRow(host.settingsLabeledField(name: "Name", hint: "Shown in the automations list.", control: makeNameField(seed: seed)), to: stack)

        if editingAutomationID == nil {
            addRow(host.settingsLabeledField(name: "Device", hint: "The device this automation runs on.", control: makeDevicePopUp()), to: stack)
        } else {
            let deviceName = deviceInputs.first(where: { $0.deviceID == deviceID })?.deviceName ?? "this device"
            let label = NSTextField(labelWithString: deviceName)
            label.font = Typography.body
            label.textColor = .secondaryLabelColor
            addRow(host.settingsLabeledField(name: "Device", hint: "An automation stays on its device.", control: label), to: stack)
        }

        addRow(host.settingsLabeledField(name: "Type", hint: "Spawn a coding agent, or run a shell script.", control: makeKindControl(seed: seed)), to: stack)

        // Agent-kind rows.
        let workspaceRow = host.settingsLabeledField(
            name: "Workspace", hint: "The workspace the coding agent spawns into.", control: makeWorkspacePopUp(seed: seed))
        addRow(workspaceRow, to: stack)
        self.workspaceRow = workspaceRow
        let agentCommandRow = host.settingsLabeledField(
            name: "Agent command", hint: "Launches a supported coding agent (claude, codex, opencode); may carry flags.",
            control: makeAgentCommandField(seed: seed))
        addRow(agentCommandRow, to: stack)
        self.agentCommandRow = agentCommandRow
        let agentPromptRow = host.settingsLabeledField(name: "Prompt", hint: "Sent to the agent once it starts.", control: makeAgentPromptEditor(seed: seed))
        addRow(agentPromptRow, to: stack)
        self.agentPromptRow = agentPromptRow

        // Script-kind rows.
        let scriptRow = host.settingsLabeledField(name: "Script", hint: "Runs in your login shell.", control: makeScriptEditor(seed: seed))
        addRow(scriptRow, to: stack)
        self.scriptRow = scriptRow
        let workingDirectoryRow = host.settingsLabeledField(
            name: "Working directory", hint: "Directory the command runs in.", control: makeWorkingDirectoryControl(seed: seed))
        addRow(workingDirectoryRow, to: stack)
        self.workingDirectoryRow = workingDirectoryRow

        addRow(host.settingsLabeledField(name: "Trigger", hint: "Run manually or on a cron schedule.", control: makeTriggerControl(seed: seed)), to: stack)
        appendCronSection(to: stack, seed: seed)

        addRow(
            host.settingsLabeledField(name: "Timeout (seconds)", hint: "Leave empty for no timeout.", control: makeTimeoutField(seed: seed)), to: stack)
        addRow(host.settingsLabeledField(name: "On overlap", hint: concurrencyHint(), control: makeConcurrencyPopUp(seed: seed)), to: stack)
        addRow(host.settingsLabeledField(name: "Missed runs", hint: missedRunHint(), control: makeMissedRunPopUp(seed: seed)), to: stack)

        let errorLabel = host.helpTextLabel("")
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        self.errorLabel = errorLabel
        addRow(errorLabel, to: stack)

        addRow(makeFooter(), to: stack)

        applyKindVisibility()
        applyScheduleVisibility()
        updatePreview()

        // The header close button targets the host (see `iconButton`), so the action must be a host
        // selector; `cancelTapped` here would silently never fire.
        let header = host.buildFormWindowHeader(
            symbol: "clock.arrow.circlepath", title: title, closeAction: #selector(AppKitController.closeAutomationEditorWindow))
        window = host.presentFormWindow(existing: window, header: header, hosting: stack)
        window?.delegate = self
    }

    private func addRow(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        host.constrainFormFieldToFillWidth(view, in: stack)
    }

    // MARK: - Field builders

    private func makeNameField(seed: TerminalServiceAutomationSummary?) -> NSView {
        let field = NSTextField(string: seed?.name ?? "")
        field.placeholderString = "Nightly audit"
        field.font = Typography.body
        nameField = field
        return field
    }

    private func makeDevicePopUp() -> NSView {
        let popUp = NSPopUpButton()
        for input in deviceInputs where input.isReachable {
            popUp.addItem(withTitle: input.deviceName)
            popUp.itemArray.last?.representedObject = input.deviceID
            if input.deviceID == deviceID { popUp.select(popUp.itemArray.last) }
        }
        popUp.target = self
        popUp.action = #selector(deviceChanged(_:))
        devicePopUp = popUp
        return popUp
    }

    private func makeKindControl(seed: TerminalServiceAutomationSummary?) -> NSView {
        currentKind = seed.flatMap { AutomationKind(rawValue: $0.kind) } ?? .agent
        let segmented = NSSegmentedControl(labels: ["Agent", "Script"], trackingMode: .selectOne, target: self, action: #selector(kindChanged(_:)))
        segmented.selectedSegment = currentKind == .script ? 1 : 0
        kindSegmented = segmented
        return segmented
    }

    private func makeWorkspacePopUp(seed: TerminalServiceAutomationSummary?) -> NSView {
        let popUp = NSPopUpButton()
        if workspaceChoices.isEmpty {
            popUp.addItem(withTitle: "No workspaces on this device")
            popUp.itemArray.last?.representedObject = nil
            popUp.isEnabled = false
        } else {
            for choice in workspaceChoices {
                popUp.addItem(withTitle: choice.label)
                popUp.itemArray.last?.representedObject = choice.workspaceID
                if choice.workspaceID == seed?.workspaceID { popUp.select(popUp.itemArray.last) }
            }
        }
        workspacePopUp = popUp
        return popUp
    }

    private func makeAgentCommandField(seed: TerminalServiceAutomationSummary?) -> NSView {
        let field = NSTextField(string: seed?.agentCommand ?? "claude")
        field.placeholderString = "claude"
        field.font = Typography.body
        agentCommandField = field
        return field
    }

    private func makeAgentPromptEditor(seed: TerminalServiceAutomationSummary?) -> NSView {
        let textView = NSTextView()
        textView.string = seed?.agentPrompt ?? ""
        textView.isRichText = false
        // Prose, not code: use the system font (matching the script editor's visual language but not its
        // monospace). Smart substitutions stay off so the prompt reaches the agent verbatim.
        textView.font = Typography.body
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        agentPromptTextView = textView
        return host.scrollableTextView(textView, height: 72)
    }

    private func makeScriptEditor(seed: TerminalServiceAutomationSummary?) -> NSView {
        let textView = NSTextView()
        textView.string = seed?.script ?? ""
        textView.isRichText = false
        textView.font = Typography.monoBody
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scriptTextView = textView
        return host.scrollableTextView(textView, height: 72)
    }

    private func makeWorkingDirectoryControl(seed: TerminalServiceAutomationSummary?) -> NSView {
        let field = NSTextField(string: seed?.workingDirectory ?? "")
        field.placeholderString = "/path/to/project"
        field.font = Typography.body
        workingDirectoryField = field
        // The Browse folder picker is only meaningful for the local device — a remote path can't be resolved
        // from this Mac's file system — so it is offered for local automations only.
        guard isLocalDevice else { return field }
        let browse = host.actionButton(title: "Browse…", symbol: "folder", tooltip: "Choose a folder", action: #selector(browseTapped), primary: false)
        browse.target = self
        let row = NSStackView(views: [field, browse])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeTriggerControl(seed: TerminalServiceAutomationSummary?) -> NSView {
        let segmented = NSSegmentedControl(
            labels: ["Manual", "Cron"], trackingMode: .selectOne, target: self, action: #selector(triggerChanged(_:)))
        segmented.selectedSegment = (seed.flatMap { AutomationTriggerKind(rawValue: $0.triggerKind) } ?? .manual) == .cron ? 1 : 0
        triggerSegmented = segmented
        return segmented
    }

    private func appendCronSection(to stack: NSStackView, seed: TerminalServiceAutomationSummary?) {
        cronSectionRows = []
        builderRows = []

        let modeSegmented = NSSegmentedControl(
            labels: ["Builder", "Advanced"], trackingMode: .selectOne, target: self, action: #selector(cronModeChanged(_:)))
        let seededPreset = seed?.cronExpression.map(AutomationSchedulePreset.from(cronExpression:))
        let opensAdvanced: Bool = if case .advanced = seededPreset { true } else { seededPreset == nil ? false : false }
        modeSegmented.selectedSegment = opensAdvanced ? CronMode.advanced.rawValue : CronMode.builder.rawValue
        cronModeSegmented = modeSegmented
        let modeRow = host.settingsLabeledField(name: "Schedule", hint: "Build a schedule or enter a raw cron expression.", control: modeSegmented)
        addRow(modeRow, to: stack)
        cronSectionRows.append(modeRow)

        let kindPopUp = NSPopUpButton()
        for kind in AutomationSchedulePreset.Kind.allCases {
            kindPopUp.addItem(withTitle: kind.title)
            kindPopUp.itemArray.last?.representedObject = kind.rawValue
        }
        kindPopUp.target = self
        kindPopUp.action = #selector(presetKindChanged(_:))
        presetKindPopUp = kindPopUp
        let kindRow = host.settingsLabeledField(name: "Preset", hint: "Choose a schedule shape.", control: kindPopUp)
        addRow(kindRow, to: stack)
        cronSectionRows.append(kindRow)
        builderRows.append(kindRow)

        // Preset parameter rows. Every-N-minutes offers only uniform divisors of 60 (a free numeric field
        // would let the user pick a step like 40 that cron does not space evenly), so it is a popup.
        let everyNPopUp = makeEveryNPopUp(selected: 15)
        self.everyNPopUp = everyNPopUp
        let everyNRow = host.settingsLabeledField(name: "Every N minutes", hint: "Uniform intervals (divisors of 60).", control: everyNPopUp)
        addRow(everyNRow, to: stack)
        self.everyNRow = everyNRow
        cronSectionRows.append(everyNRow)
        builderRows.append(everyNRow)

        let hourlyMinuteField = makeIntegerField(range: 0...59, value: 0)
        self.hourlyMinuteField = hourlyMinuteField
        let hourlyRow = host.settingsLabeledField(name: "At minute", hint: "0–59, each hour.", control: hourlyMinuteField)
        addRow(hourlyRow, to: stack)
        self.hourlyRow = hourlyRow
        cronSectionRows.append(hourlyRow)
        builderRows.append(hourlyRow)

        let dailyHourField = makeIntegerField(range: 0...23, value: 9)
        let dailyMinuteField = makeIntegerField(range: 0...59, value: 0)
        self.dailyHourField = dailyHourField
        self.dailyMinuteField = dailyMinuteField
        let dailyRow = host.settingsLabeledField(name: "Daily at", hint: "Hour (0–23) and minute (0–59).", control: makeTimeRow(dailyHourField, dailyMinuteField))
        addRow(dailyRow, to: stack)
        self.dailyRow = dailyRow
        cronSectionRows.append(dailyRow)
        builderRows.append(dailyRow)

        let weeklyHourField = makeIntegerField(range: 0...23, value: 9)
        let weeklyMinuteField = makeIntegerField(range: 0...59, value: 0)
        self.weeklyHourField = weeklyHourField
        self.weeklyMinuteField = weeklyMinuteField
        let weeklyRow = host.settingsLabeledField(
            name: "Weekly on", hint: "Days plus time.", control: makeWeeklyControl(hour: weeklyHourField, minute: weeklyMinuteField))
        addRow(weeklyRow, to: stack)
        self.weeklyRow = weeklyRow
        cronSectionRows.append(weeklyRow)
        builderRows.append(weeklyRow)

        let advancedField = NSTextField(string: "")
        advancedField.placeholderString = "*/15 * * * *"
        advancedField.font = Typography.monoBody
        advancedField.target = self
        advancedField.action = #selector(scheduleValueChanged)
        advancedField.delegate = self
        advancedCronField = advancedField
        let advancedRow = host.settingsLabeledField(
            name: "Cron expression", hint: "minute hour day-of-month month day-of-week", control: advancedField)
        addRow(advancedRow, to: stack)
        self.advancedRow = advancedRow
        cronSectionRows.append(advancedRow)

        let previewLabel = host.helpTextLabel("")
        self.previewLabel = previewLabel
        addRow(previewLabel, to: stack)
        cronSectionRows.append(previewLabel)

        seedScheduleControls(preset: seededPreset)
    }

    private func seedScheduleControls(preset: AutomationSchedulePreset?) {
        switch preset {
        case .everyNMinutes(let minutes):
            presetKindPopUp?.selectItem(at: indexOfKind(.everyNMinutes))
            // `from(cronExpression:)` only ever derives an everyNMinutes preset for an N in the choices, so a
            // stored value always matches an item; leave the default selected if it somehow does not.
            if let index = AutomationSchedulePreset.everyNMinutesChoices.firstIndex(of: minutes) { everyNPopUp?.selectItem(at: index) }
        case .hourlyAtMinute(let minute):
            presetKindPopUp?.selectItem(at: indexOfKind(.hourlyAtMinute))
            hourlyMinuteField?.integerValue = minute
        case .dailyAtTime(let hour, let minute):
            presetKindPopUp?.selectItem(at: indexOfKind(.dailyAtTime))
            dailyHourField?.integerValue = hour
            dailyMinuteField?.integerValue = minute
        case .weeklyOnDaysAtTime(let days, let hour, let minute):
            presetKindPopUp?.selectItem(at: indexOfKind(.weeklyOnDaysAtTime))
            weeklyHourField?.integerValue = hour
            weeklyMinuteField?.integerValue = minute
            for (index, checkbox) in weeklyDayCheckboxes.enumerated() { checkbox.state = days.contains(index) ? .on : .off }
        case .advanced(let expression):
            advancedCronField?.stringValue = expression
        case nil:
            break
        }
    }

    private func indexOfKind(_ kind: AutomationSchedulePreset.Kind) -> Int {
        AutomationSchedulePreset.Kind.allCases.firstIndex(of: kind) ?? 0
    }

    /// Builds the every-N-minutes popup from the preset's canonical divisor choices, each item carrying its
    /// integer value as its represented object so the read path recovers it directly.
    private func makeEveryNPopUp(selected: Int) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        for choice in AutomationSchedulePreset.everyNMinutesChoices {
            popUp.addItem(withTitle: "\(choice)")
            popUp.itemArray.last?.representedObject = choice
        }
        popUp.selectItem(at: AutomationSchedulePreset.everyNMinutesChoices.firstIndex(of: selected) ?? 0)
        popUp.target = self
        popUp.action = #selector(scheduleValueChanged)
        return popUp
    }

    private func makeIntegerField(range: ClosedRange<Int>, value: Int) -> NSTextField {
        let field = NSTextField(string: "\(value)")
        field.font = Typography.body
        field.alignment = .right
        field.target = self
        field.action = #selector(scheduleValueChanged)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return field
    }

    private func makeTimeRow(_ hour: NSTextField, _ minute: NSTextField) -> NSView {
        let colon = NSTextField(labelWithString: ":")
        let row = NSStackView(views: [hour, colon, minute, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func makeWeeklyControl(hour: NSTextField, minute: NSTextField) -> NSView {
        let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        weeklyDayCheckboxes = dayNames.map { name in
            let checkbox = NSButton(checkboxWithTitle: name, target: self, action: #selector(scheduleValueChanged))
            return checkbox
        }
        let daysRow = NSStackView(views: weeklyDayCheckboxes)
        daysRow.orientation = .horizontal
        daysRow.spacing = 6
        let timeRow = makeTimeRow(hour, minute)
        let column = NSStackView(views: [daysRow, timeRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        return column
    }

    private func makeTimeoutField(seed: TerminalServiceAutomationSummary?) -> NSView {
        let field = NSTextField(string: seed?.timeoutSeconds.map(String.init) ?? "")
        field.placeholderString = "none"
        field.font = Typography.body
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        timeoutField = field
        let row = NSStackView(views: [field, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    private func makeConcurrencyPopUp(seed: TerminalServiceAutomationSummary?) -> NSView {
        let popUp = NSPopUpButton()
        for policy in AutomationConcurrencyPolicy.allCases {
            popUp.addItem(withTitle: Self.concurrencyTitle(policy))
            popUp.itemArray.last?.representedObject = policy.rawValue
        }
        let seeded = seed.flatMap { AutomationConcurrencyPolicy(rawValue: $0.concurrencyPolicy) } ?? .allow
        popUp.selectItem(at: AutomationConcurrencyPolicy.allCases.firstIndex(of: seeded) ?? 0)
        concurrencyPopUp = popUp
        return popUp
    }

    private func makeMissedRunPopUp(seed: TerminalServiceAutomationSummary?) -> NSView {
        let popUp = NSPopUpButton()
        for policy in AutomationMissedRunPolicy.allCases {
            popUp.addItem(withTitle: Self.missedRunTitle(policy))
            popUp.itemArray.last?.representedObject = policy.rawValue
        }
        let seeded = seed.flatMap { AutomationMissedRunPolicy(rawValue: $0.missedRunPolicy) } ?? .runOnce
        popUp.selectItem(at: AutomationMissedRunPolicy.allCases.firstIndex(of: seeded) ?? 0)
        missedRunPopUp = popUp
        return popUp
    }

    private func makeFooter() -> NSView {
        let cancel = host.actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelTapped), primary: false)
        cancel.target = self
        cancel.keyEquivalent = "\u{1b}"
        let save = host.actionButton(title: "Save", symbol: nil, tooltip: "Save", action: #selector(saveTapped), primary: true)
        save.target = self
        save.keyEquivalent = "\r"
        save.isEnabled = !isSaving
        saveButton = save
        let row = NSStackView(views: [NSView(), cancel, save])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return row
    }

    // MARK: - Descriptions

    private static func concurrencyTitle(_ policy: AutomationConcurrencyPolicy) -> String {
        switch policy {
        case .allow: "Allow — always start a new run"
        case .skip: "Skip — record a skipped run"
        case .queue: "Queue — run after the current one"
        }
    }

    private static func missedRunTitle(_ policy: AutomationMissedRunPolicy) -> String {
        switch policy {
        case .runOnce: "Run once — one catch-up run"
        case .skip: "Skip — record a skipped run"
        }
    }

    private func concurrencyHint() -> String { "What happens when a fire lands while an earlier run is still going." }
    private func missedRunHint() -> String { "What a restarted daemon does with a fire it missed while down." }

    // MARK: - Visibility & preview

    /// Shows the agent form or the script form for the current kind. Shared fields stay visible for both.
    private func applyKindVisibility() {
        let isAgent = currentKind == .agent
        workspaceRow?.isHidden = !isAgent
        agentCommandRow?.isHidden = !isAgent
        agentPromptRow?.isHidden = !isAgent
        scriptRow?.isHidden = isAgent
        workingDirectoryRow?.isHidden = isAgent
    }

    /// Prefills the script editor with the CLI equivalent of the current agent form when switching
    /// Agent → Script — but only when the editor is empty or still holds a previous auto-prefill, so
    /// script the user typed themselves is never clobbered. The working directory is left for the user to fill.
    private func prefillScriptFromAgentIfAppropriate() {
        let current = scriptTextView?.string ?? ""
        guard current.isEmpty || current == lastGeneratedScriptPrefill else { return }
        let workspaceID = (workspacePopUp?.selectedItem?.representedObject as? String) ?? ""
        let command = agentCommandField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let generated = AutomationsViewModel.agentEquivalentScript(
            workspaceID: workspaceID, command: command.isEmpty ? "claude" : command, prompt: agentPromptTextView?.string ?? "")
        scriptTextView?.string = generated
        lastGeneratedScriptPrefill = generated
    }

    private func applyScheduleVisibility() {
        let isCron = (triggerSegmented?.selectedSegment ?? 0) == 1
        for row in cronSectionRows { row.isHidden = !isCron }
        guard isCron else { return }
        let mode = CronMode(rawValue: cronModeSegmented?.selectedSegment ?? 0) ?? .builder
        let isBuilder = mode == .builder
        for row in builderRows { row.isHidden = !isBuilder }
        advancedRow?.isHidden = isBuilder
        if isBuilder {
            let kind = selectedKind()
            everyNRow?.isHidden = kind != .everyNMinutes
            hourlyRow?.isHidden = kind != .hourlyAtMinute
            dailyRow?.isHidden = kind != .dailyAtTime
            weeklyRow?.isHidden = kind != .weeklyOnDaysAtTime
        }
    }

    private func selectedKind() -> AutomationSchedulePreset.Kind {
        (presetKindPopUp?.selectedItem?.representedObject as? String).flatMap(AutomationSchedulePreset.Kind.init(rawValue:)) ?? .everyNMinutes
    }

    /// The builder state currently expressed by the controls (nil for a manual automation).
    private func currentPreset() -> AutomationSchedulePreset? {
        guard (triggerSegmented?.selectedSegment ?? 0) == 1 else { return nil }
        let mode = CronMode(rawValue: cronModeSegmented?.selectedSegment ?? 0) ?? .builder
        if mode == .advanced { return .advanced(expression: advancedCronField?.stringValue ?? "") }
        switch selectedKind() {
        case .everyNMinutes:
            return .everyNMinutes(minutes: (everyNPopUp?.selectedItem?.representedObject as? Int) ?? AutomationSchedulePreset.everyNMinutesChoices[0])
        case .hourlyAtMinute: return .hourlyAtMinute(minute: hourlyMinuteField?.integerValue ?? 0)
        case .dailyAtTime: return .dailyAtTime(hour: dailyHourField?.integerValue ?? 0, minute: dailyMinuteField?.integerValue ?? 0)
        case .weeklyOnDaysAtTime:
            let days = Set(weeklyDayCheckboxes.enumerated().filter { $0.element.state == .on }.map(\.offset))
            return .weeklyOnDaysAtTime(days: days, hour: weeklyHourField?.integerValue ?? 0, minute: weeklyMinuteField?.integerValue ?? 0)
        }
    }

    private func updatePreview() {
        guard let previewLabel else { return }
        guard let preset = currentPreset() else {
            previewLabel.stringValue = ""
            return
        }
        if case .weeklyOnDaysAtTime(let days, _, _) = preset, days.isEmpty {
            previewLabel.textColor = .systemRed
            previewLabel.stringValue = "Select at least one day."
            return
        }
        do {
            // Preview in the zone the target device evaluates cron in: the Mac's own zone for the local
            // device, else the remote device's daemon-reported zone. A cross-zone remote preview would
            // otherwise show the Mac's wall-clock times, not the device's.
            let reportedZoneID = deviceInputs.first(where: { $0.deviceID == deviceID })?.timeZoneIdentifier
            let previewZone = AutomationsViewModel.schedulePreviewTimeZone(
                isLocalDevice: isLocalDevice, reportedTimeZoneIdentifier: reportedZoneID)
            let runs = try AutomationSchedulePreview.nextRuns(cronExpression: preset.cronExpression, after: Date(), timeZone: previewZone, count: 3)
            previewLabel.textColor = .secondaryLabelColor
            if runs.isEmpty {
                previewLabel.stringValue = "This schedule has no upcoming runs."
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                formatter.timeZone = previewZone
                var text = "Next runs: " + runs.map { formatter.string(from: $0) }.joined(separator: ", ")
                // Show the zone only when it differs from the Mac's, so local authoring stays uncluttered.
                if let zoneSuffix = AutomationsViewModel.schedulePreviewZoneSuffix(previewTimeZone: previewZone) { text += " (\(zoneSuffix))" }
                previewLabel.stringValue = text
            }
        } catch {
            previewLabel.textColor = .systemRed
            previewLabel.stringValue = error.localizedDescription
        }
    }

    // MARK: - Actions

    @objc private func deviceChanged(_ sender: NSPopUpButton) {
        let newDeviceID = (sender.selectedItem?.representedObject as? String) ?? deviceID
        guard newDeviceID != deviceID else { return }
        deviceID = newDeviceID
        isLocalDevice = deviceInputs.first(where: { $0.deviceID == deviceID })?.isLocal ?? false
        // Re-present so the workspace list (agent form) and the working-directory Browse button (local only)
        // match the newly selected device.
        rebuildPreservingValues()
    }

    @objc private func kindChanged(_ sender: NSSegmentedControl) {
        let newKind: AutomationKind = sender.selectedSegment == 1 ? .script : .agent
        guard newKind != currentKind else { return }
        // Prefill the script only when moving Agent → Script; the reverse just reveals the agent form.
        if newKind == .script { prefillScriptFromAgentIfAppropriate() }
        currentKind = newKind
        applyKindVisibility()
    }

    @objc private func triggerChanged(_ sender: NSSegmentedControl) {
        applyScheduleVisibility()
        updatePreview()
    }

    @objc private func cronModeChanged(_ sender: NSSegmentedControl) {
        applyScheduleVisibility()
        updatePreview()
    }

    @objc private func presetKindChanged(_ sender: NSPopUpButton) {
        applyScheduleVisibility()
        updatePreview()
    }

    @objc private func scheduleValueChanged() { updatePreview() }

    /// Live-updates the schedule preview as the user types in an integer or advanced-cron field.
    func controlTextDidChange(_ obj: Notification) { updatePreview() }

    @objc private func browseTapped() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = workingDirectoryField?.stringValue, !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectoryField?.stringValue = url.path
    }

    @objc private func cancelTapped() { window?.performClose(nil) }

    /// Host-forwarded close for the header X button, which cannot target this controller directly.
    func closeWindow() { window?.performClose(nil) }

    @objc private func saveTapped() {
        guard !isSaving else { return }
        guard let fields = collectFields() else { return }
        let deviceID = self.deviceID
        let editingID = editingAutomationID
        guard let device = host.automationDeviceRecord(deviceID: deviceID) else {
            showError("That device is not available.")
            return
        }
        let forceRemoteRefresh = host.isRemoteAutomationDevice(deviceID: deviceID)
        // Set the flag synchronously before spawning the Task, so a second click or Return press arriving
        // before the first request completes is rejected at the guard above. Disabling the button gives
        // immediate visual feedback. The device popup is frozen too: changing the device rebuilds the form
        // via `present`, which resets `isSaving` and mints a fresh enabled Save button — a second save would
        // then fire a duplicate create. A request already being written must not have its target device
        // mutated, so the only rebuild trigger stays disabled until the request settles.
        isSaving = true
        saveButton?.isEnabled = false
        devicePopUp?.isEnabled = false
        Task { @MainActor [weak self] in
            let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
                    if let editingID {
                        _ = try SpacesDeviceClient.updateAutomation(id: editingID, fields: fields, device: device, clientApp: clientApp)
                    } else {
                        _ = try SpacesDeviceClient.createAutomation(fields, device: device, clientApp: clientApp)
                    }
                    return nil
                } catch { return error }
            }.value
            guard let self else { return }
            if let error {
                self.isSaving = false
                self.saveButton?.isEnabled = true
                self.devicePopUp?.isEnabled = true
                showError(error.localizedDescription)
                return
            }
            window?.performClose(nil)
            host.requestSidebarReload(forceRemoteRefresh: forceRemoteRefresh)
        }
    }

    /// Reads the controls into validated wire fields, surfacing the first problem inline and returning nil.
    /// The shared cron/timeout resolution lives here; the name check and kind-specific field validation and
    /// assembly are delegated to `AutomationsViewModel.buildAutomationFields` so they stay unit-testable.
    private func collectFields() -> TerminalServiceAutomationFields? {
        var timeoutSeconds: Int?
        if let timeoutText = timeoutField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !timeoutText.isEmpty {
            guard let value = Int(timeoutText), value > 0 else { return failValidation("Timeout must be a positive number of seconds, or empty.") }
            timeoutSeconds = value
        }

        let isCron = (triggerSegmented?.selectedSegment ?? 0) == 1
        let triggerKind: AutomationTriggerKind = isCron ? .cron : .manual
        var cronExpression: String?
        if isCron {
            guard let preset = currentPreset() else { return failValidation("Configure the schedule.") }
            if case .weeklyOnDaysAtTime(let days, _, _) = preset, days.isEmpty { return failValidation("Select at least one day.") }
            let expression = preset.cronExpression
            // Validate locally so a bad expression is caught inline before the round-trip.
            do { _ = try AutomationCronSchedule.parse(expression) } catch { return failValidation(error.localizedDescription) }
            cronExpression = expression
        }

        let concurrency = (concurrencyPopUp?.selectedItem?.representedObject as? String) ?? AutomationConcurrencyPolicy.allow.rawValue
        let missed = (missedRunPopUp?.selectedItem?.representedObject as? String) ?? AutomationMissedRunPolicy.runOnce.rawValue

        let result = AutomationsViewModel.buildAutomationFields(
            name: nameField?.stringValue ?? "", kind: currentKind, enabled: currentEnabled(), triggerKind: triggerKind,
            cronExpression: cronExpression, workspaceID: workspacePopUp?.selectedItem?.representedObject as? String,
            agentCommand: agentCommandField?.stringValue ?? "", agentPrompt: agentPromptTextView?.string ?? "",
            script: scriptTextView?.string ?? "", workingDirectory: workingDirectoryField?.stringValue ?? "", timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrency, missedRunPolicy: missed)
        switch result {
        case .success(let fields):
            errorLabel?.isHidden = true
            return fields
        case .failure(let error):
            return failValidation(error.message)
        }
    }

    /// Preserves the automation's enabled state across edits; a newly created automation is enabled.
    private func currentEnabled() -> Bool {
        guard let editingAutomationID, let automation = host.automationSummary(deviceID: deviceID, automationID: editingAutomationID) else { return true }
        return automation.enabled
    }

    private func failValidation(_ message: String) -> TerminalServiceAutomationFields? {
        showError(message)
        return nil
    }

    private func showError(_ message: String) {
        errorLabel?.stringValue = message
        errorLabel?.isHidden = false
    }

    /// Re-presents the form, carrying the current control values forward (used when device locality flips the
    /// Browse button in/out). Reads the live controls into a seed summary so nothing typed is lost.
    private func rebuildPreservingValues() {
        present(title: editingAutomationID == nil ? "New Automation" : "Edit Automation", seed: collectRawFieldsForRebuild())
    }

    /// Snapshots the current controls into a summary for a rebuild, bypassing validation (values may be
    /// mid-edit). The cron string comes from the current builder/advanced state.
    private func collectRawFieldsForRebuild() -> TerminalServiceAutomationSummary {
        let isCron = (triggerSegmented?.selectedSegment ?? 0) == 1
        return TerminalServiceAutomationSummary(
            id: editingAutomationID ?? "", name: nameField?.stringValue ?? "", enabled: currentEnabled(),
            triggerKind: (isCron ? AutomationTriggerKind.cron : .manual).rawValue, cronExpression: isCron ? currentPreset()?.cronExpression : nil,
            kind: currentKind.rawValue, script: scriptTextView?.string ?? "", agentCommand: agentCommandField?.stringValue,
            agentPrompt: agentPromptTextView?.string, workspaceID: workspacePopUp?.selectedItem?.representedObject as? String,
            workingDirectory: workingDirectoryField?.stringValue ?? "", timeoutSeconds: timeoutField.flatMap { Int($0.stringValue) },
            concurrencyPolicy: (concurrencyPopUp?.selectedItem?.representedObject as? String) ?? AutomationConcurrencyPolicy.allow.rawValue,
            missedRunPolicy: (missedRunPopUp?.selectedItem?.representedObject as? String) ?? AutomationMissedRunPolicy.runOnce.rawValue,
            nextFireTime: nil, createdAt: "", updatedAt: "")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
    }
}
