import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Owns the create/edit automation form window. `AppKitController` holds one instance; the unowned `host`
/// gives access to the shared form-window chrome and device services. The cron schedule builder serializes to
/// a cron string via `AutomationSchedulePreset` — the string is the only stored form — and shows a live
/// next-3-runs preview plus inline parse validation. The device is chosen only at create time; an automation
/// lives on its device, so edit fixes it.
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

    // Live control references, valid while the window is open.
    private var nameField: NSTextField?
    private var devicePopUp: NSPopUpButton?
    private var scriptTextView: NSTextView?
    private var workingDirectoryField: NSTextField?
    private var triggerSegmented: NSSegmentedControl?
    private var cronModeSegmented: NSSegmentedControl?
    private var presetKindPopUp: NSPopUpButton?
    private var everyNField: NSTextField?
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
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            addRow(host.settingsLabeledField(name: "Device", hint: "An automation stays on its device.", control: label), to: stack)
        }

        addRow(host.settingsLabeledField(name: "Script", hint: "Runs in your login shell.", control: makeScriptEditor(seed: seed)), to: stack)
        addRow(
            host.settingsLabeledField(
                name: "Working directory", hint: "Directory the command runs in.", control: makeWorkingDirectoryControl(seed: seed)), to: stack)

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

        applyScheduleVisibility()
        updatePreview()

        let header = host.buildFormWindowHeader(symbol: "clock.arrow.circlepath", title: title, closeAction: #selector(cancelTapped))
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
        field.font = .systemFont(ofSize: 13)
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

    private func makeScriptEditor(seed: TerminalServiceAutomationSummary?) -> NSView {
        let textView = NSTextView()
        textView.string = seed?.script ?? ""
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        field.font = .systemFont(ofSize: 13)
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

        // Preset parameter rows.
        let everyNField = makeIntegerField(range: 2...59, value: 15)
        self.everyNField = everyNField
        let everyNRow = host.settingsLabeledField(name: "Every N minutes", hint: "2–59.", control: everyNField)
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
        advancedField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
            everyNField?.integerValue = minutes
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

    private func makeIntegerField(range: ClosedRange<Int>, value: Int) -> NSTextField {
        let field = NSTextField(string: "\(value)")
        field.font = .systemFont(ofSize: 13)
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
        field.font = .systemFont(ofSize: 13)
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
        case .everyNMinutes: return .everyNMinutes(minutes: everyNField?.integerValue ?? 0)
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
            let runs = try AutomationSchedulePreview.nextRuns(cronExpression: preset.cronExpression, after: Date(), timeZone: .current, count: 3)
            previewLabel.textColor = .secondaryLabelColor
            if runs.isEmpty {
                previewLabel.stringValue = "This schedule has no upcoming runs."
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                previewLabel.stringValue = "Next runs: " + runs.map { formatter.string(from: $0) }.joined(separator: ", ")
            }
        } catch {
            previewLabel.textColor = .systemRed
            previewLabel.stringValue = error.localizedDescription
        }
    }

    // MARK: - Actions

    @objc private func deviceChanged(_ sender: NSPopUpButton) {
        deviceID = (sender.selectedItem?.representedObject as? String) ?? deviceID
        let wasLocal = isLocalDevice
        isLocalDevice = deviceInputs.first(where: { $0.deviceID == deviceID })?.isLocal ?? false
        // Re-present so the working-directory Browse button appears/disappears with device locality.
        if wasLocal != isLocalDevice { rebuildPreservingValues() }
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

    @objc private func saveTapped() {
        guard let fields = collectFields() else { return }
        let deviceID = self.deviceID
        let editingID = editingAutomationID
        guard let device = host.automationDeviceRecord(deviceID: deviceID) else {
            showError("That device is not available.")
            return
        }
        let forceRemoteRefresh = host.isRemoteAutomationDevice(deviceID: deviceID)
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
                showError(error.localizedDescription)
                return
            }
            window?.performClose(nil)
            host.requestSidebarReload(forceRemoteRefresh: forceRemoteRefresh)
        }
    }

    /// Reads the controls into validated wire fields, surfacing the first problem inline and returning nil.
    private func collectFields() -> TerminalServiceAutomationFields? {
        let name = nameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return failValidation("Enter a name.") }
        let script = scriptTextView?.string ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return failValidation("Enter a script.") }
        let workingDirectory = workingDirectoryField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !workingDirectory.isEmpty else { return failValidation("Enter a working directory.") }

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

        errorLabel?.isHidden = true
        // Kind is fixed to `.script` here: the editor has no type toggle yet (a later commit adds one), so
        // every automation authored through this form is a script automation.
        return TerminalServiceAutomationFields(
            name: name, enabled: currentEnabled(), triggerKind: triggerKind.rawValue, cronExpression: cronExpression,
            kind: AutomationKind.script.rawValue, script: script, workingDirectory: workingDirectory, timeoutSeconds: timeoutSeconds,
            concurrencyPolicy: concurrency, missedRunPolicy: missed)
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
            kind: AutomationKind.script.rawValue, script: scriptTextView?.string ?? "", workingDirectory: workingDirectoryField?.stringValue ?? "",
            timeoutSeconds: timeoutField.flatMap { Int($0.stringValue) },
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
