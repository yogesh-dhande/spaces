import Foundation
import Testing
import spacesterminalcore
import workspacecore

@testable import spacesui

/// `AlertsController.alertsTableRows` is the pure, host-free derivation behind the Alerts pane's single
/// cross-device table: it merges every visible device's groups into one newest-first row list, numbers
/// each row's window shortcut, and resolves the Device column's text and the offline dimming flag. Kept
/// separate from `AlertsControllerBuilderTests` (which covers the per-device group builder) since this
/// suite is about ordering, numbering, and device-display resolution across groups already built.
@Suite struct AlertsTableRowsTests {
    private func entry(
        id: String, label: String = "row", detail: String? = nil, eventDate: Date?, focusRequest: AppKitController.WindowFocusRequest? = nil,
        automationRunTarget: AlertsController.AutomationRunAlertTarget? = nil
    ) -> AlertsController.AlertsAttentionEntry {
        AlertsController.AlertsAttentionEntry(
            attentionID: id, kind: .bell, icon: "terminal", iconTint: .terminal, label: label, detail: detail, shortcut: "", countsTowardBadge: true,
            eventDate: eventDate, focusRequest: focusRequest, automationRunTarget: automationRunTarget)
    }

    private func group(
        deviceID: String, workspaceID: String = "ws", projectName: String = "Project", workspaceName: String = "feature",
        items: [AlertsController.AlertsAttentionEntry]
    ) -> AlertsController.AlertsGroup {
        AlertsController.AlertsGroup(
            projectName: projectName, workspaceID: workspaceID, workspaceName: workspaceName, workspaceBranch: nil, isFromHiddenWorkspace: false,
            items: items, deviceID: deviceID)
    }

    private func date(_ offsetMinutes: Int, from base: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)) -> Date {
        base.addingTimeInterval(TimeInterval(offsetMinutes * 60))
    }

    // MARK: - Cross-device ordering

    /// Every device's rows merge into one newest-first list, and an undated alert sorts after every dated
    /// one regardless of which device or group it came from.
    @Test func rowsFromEveryDeviceInterleaveNewestFirstWithUndatedLast() {
        let mac = group(
            deviceID: "mac", workspaceID: "ws-mac", items: [entry(id: "mac-old", eventDate: date(-30)), entry(id: "mac-new", eventDate: date(0))])
        let linux = group(deviceID: "linux", workspaceID: "ws-linux", items: [entry(id: "linux-mid", eventDate: date(-10))])
        let undated = group(deviceID: "mac", workspaceID: "ws-undated", items: [entry(id: "mac-undated", eventDate: nil)])

        let rows = AlertsController.alertsTableRows(groups: [mac, linux, undated], deviceDisplay: [:], showsDeviceColumn: false, now: date(0))

        #expect(rows.map(\.entry.attentionID) == ["mac-new", "linux-mid", "mac-old", "mac-undated"])
    }

    /// `Array.sorted` is stable, so two alerts with the same timestamp keep the order their groups already
    /// handed in rather than an arbitrary tie-break.
    @Test func equalTimestampsKeepIncomingOrder() {
        let tied = date(0)
        let first = group(deviceID: "mac", workspaceID: "ws-a", items: [entry(id: "a", eventDate: tied)])
        let second = group(deviceID: "linux", workspaceID: "ws-b", items: [entry(id: "b", eventDate: tied)])

        let rows = AlertsController.alertsTableRows(groups: [first, second], deviceDisplay: [:], showsDeviceColumn: false, now: tied)

        #expect(rows.map(\.entry.attentionID) == ["a", "b"])
    }

    // MARK: - Shortcut numbering

    /// The first ten rows in table order get sequential shortcut numbers; every row past the tenth gets
    /// none, matching the ⌘1-⌘0 badges the pane can show.
    @Test func onlyTheFirstTenRowsInTableOrderGetShortcutNumbers() {
        let items = (0..<12).map { entry(id: "row-\($0)", eventDate: date(-$0)) }
        let rows = AlertsController.alertsTableRows(
            groups: [group(deviceID: "mac", items: items)], deviceDisplay: [:], showsDeviceColumn: false, now: date(0))

        #expect(rows.count == 12)
        #expect(rows.prefix(10).map(\.shortcutIndex) == (1...10).map { $0 })
        #expect(rows[10].shortcutIndex == nil)
        #expect(rows[11].shortcutIndex == nil)
    }

    // MARK: - Device column

    /// `deviceText` mirrors the `showsDeviceColumn` flag the caller resolved from device count: present
    /// with that device's display name when the column shows, nil (not merely blank) when it does not, so
    /// the row builder never has to re-derive whether to show the column.
    @Test func deviceTextIsPresentOnlyWhenTheColumnShows() {
        let g = group(deviceID: "mac", items: [entry(id: "a", eventDate: date(0))])
        let display = ["mac": AlertsController.AlertsDeviceDisplay(name: "Yogesh's MacBook", isOffline: false)]

        let withColumn = AlertsController.alertsTableRows(groups: [g], deviceDisplay: display, showsDeviceColumn: true, now: date(0))
        #expect(withColumn[0].deviceText == "Yogesh's MacBook")

        let withoutColumn = AlertsController.alertsTableRows(groups: [g], deviceDisplay: display, showsDeviceColumn: false, now: date(0))
        #expect(withoutColumn[0].deviceText == nil)
    }

    // MARK: - Offline dimming

    /// A row dims when its owning device is offline, including an automation row: its synthetic
    /// `"automations:<deviceID>"` workspace id never resolves through a workspace lookup, which is why
    /// `AlertsGroup` carries `deviceID` directly rather than requiring the row to parse it back out.
    @Test func rowsFromAnOfflineDeviceCarryTheOfflineFlagIncludingAutomationRows() {
        let workspaceRow = group(deviceID: "linux", workspaceID: "ws", items: [entry(id: "workspace-alert", eventDate: date(0))])
        let automationRow = group(
            deviceID: "linux", workspaceID: "automations:linux", projectName: "Automations", workspaceName: "Linux box",
            items: [
                entry(
                    id: "automation-alert", eventDate: date(-1),
                    automationRunTarget: AlertsController.AutomationRunAlertTarget(deviceID: "linux", runID: "run-1"))
            ])
        let display = ["linux": AlertsController.AlertsDeviceDisplay(name: "Linux box", isOffline: true)]

        let rows = AlertsController.alertsTableRows(
            groups: [workspaceRow, automationRow], deviceDisplay: display, showsDeviceColumn: true, now: date(0))

        #expect(rows.allSatisfy { $0.isOffline })
        #expect(rows.first { $0.entry.attentionID == "automation-alert" }?.isAutomationsRow == true)
    }

    /// The dismiss control follows whether the owning device can take a request: the device records the
    /// dismissal, so a row of a device that cannot act cannot be dismissed.
    @Test func dismissingIsOfferedOnlyForADeviceThatCanAct() {
        let mac = group(deviceID: "mac", workspaceID: "ws-mac", items: [entry(id: "mac-alert", eventDate: date(0))])
        let linux = group(deviceID: "linux", workspaceID: "ws-linux", items: [entry(id: "linux-alert", eventDate: date(-1))])
        let display = [
            "mac": AlertsController.AlertsDeviceDisplay(name: "Mac", isOffline: false),
            "linux": AlertsController.AlertsDeviceDisplay(name: "Linux box", isOffline: true, acceptsActions: false),
        ]

        let rows = AlertsController.alertsTableRows(groups: [mac, linux], deviceDisplay: display, showsDeviceColumn: true, now: date(0))

        #expect(rows.first { $0.entry.attentionID == "mac-alert" }?.canDismiss == true)
        #expect(rows.first { $0.entry.attentionID == "linux-alert" }?.canDismiss == false)
    }

    /// A device with no entry in `deviceDisplay` (not yet loaded) reads as reachable rather than offline:
    /// there is no evidence either way, and treating "unknown" as "offline" would dim every row on first
    /// paint before any device section has loaded.
    @Test func aDeviceMissingFromDeviceDisplayIsNotTreatedAsOffline() {
        let g = group(deviceID: "not-yet-loaded", items: [entry(id: "a", eventDate: date(0))])
        let rows = AlertsController.alertsTableRows(groups: [g], deviceDisplay: [:], showsDeviceColumn: true, now: date(0))
        #expect(rows[0].isOffline == false)
    }

    // MARK: - Age text

    /// Age is derived at the instant `now` is passed in, independent of wall-clock time at test-run time,
    /// so the boundary between magnitudes ("now" vs "1m", "59m" vs "1h") is exactly reproducible.
    @Test func ageTextIsDerivedFromTheSuppliedNowAtEachMagnitudeBoundary() {
        let now = date(0)
        let g = group(
            deviceID: "mac",
            items: [
                entry(id: "just-now", eventDate: now.addingTimeInterval(-30)), entry(id: "one-minute", eventDate: now.addingTimeInterval(-60)),
                entry(id: "one-hour", eventDate: now.addingTimeInterval(-3600)), entry(id: "undated", eventDate: nil),
            ])

        let rows = AlertsController.alertsTableRows(groups: [g], deviceDisplay: [:], showsDeviceColumn: false, now: now)
        let ageByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.entry.attentionID, $0.ageText) })

        #expect(ageByID["just-now"] == "now")
        #expect(ageByID["one-minute"] == "1m")
        #expect(ageByID["one-hour"] == "1h")
        #expect(ageByID["undated"] == "", "an alert with no timestamp has no age to show")
    }
}

/// `AlertsController.alertsCombinedSegments` decides which of project, workspace, name, and title appear
/// in the Alert column's combined line, and in what order, decoupled from `NSTextField` construction.
@Suite struct AlertsCombinedSegmentsTests {
    private func entry(label: String, detail: String?) -> AlertsController.AlertsAttentionEntry {
        AlertsController.AlertsAttentionEntry(
            attentionID: "a", kind: .bell, icon: "terminal", iconTint: .terminal, label: label, detail: detail, shortcut: "", countsTowardBadge: true,
            eventDate: nil)
    }

    private func row(
        entry: AlertsController.AlertsAttentionEntry, isAutomationsRow: Bool = false, projectName: String = "Project",
        workspaceName: String = "feature"
    ) -> AlertsController.AlertsRenderPlan.Row {
        AlertsController.AlertsRenderPlan.Row(
            entry: entry, projectName: projectName, isAutomationsRow: isAutomationsRow, workspaceName: workspaceName, deviceText: nil,
            isOffline: false, canDismiss: true, ageText: "now", shortcutIndex: 1)
    }

    /// A workspace alert with a title reads `project / workspace / name / title`, the confirmed final
    /// composition; changing which segments appear (or their order) is a one-line edit to this function.
    @Test func workspaceAlertWithATitleComposesProjectWorkspaceNameTitle() {
        let segments = AlertsController.alertsCombinedSegments(
            row: row(entry: entry(label: "build box", detail: "vim main.swift"), projectName: "spaces", workspaceName: "feature-x"))

        #expect(segments.map(\.kind) == [.project, .separator, .workspace, .separator, .name, .separator, .title])
        #expect(segments.map(\.text) == ["spaces", "/", "feature-x", "/", "build box", "/", "vim main.swift"])
    }

    /// No title segment (or its separator) when there is nothing for it to show.
    @Test func aRowWithNoDetailOmitsTheTitleSegmentAndItsSeparator() {
        let segments = AlertsController.alertsCombinedSegments(row: row(entry: entry(label: "build box", detail: nil)))
        #expect(segments.map(\.kind) == [.project, .separator, .workspace, .separator, .name])
    }

    /// A title that only repeats the name earns its row no new information, so it is left out exactly as
    /// an absent title is.
    @Test func aTitleEqualToTheNameIsOmitted() {
        let segments = AlertsController.alertsCombinedSegments(row: row(entry: entry(label: "build box", detail: "build box")))
        #expect(segments.map(\.kind) == [.project, .separator, .workspace, .separator, .name])
    }

    /// An automation-run alert has no live workspace to name, so it reads as `name / title`: the
    /// automation's name, then the run's outcome.
    @Test func anAutomationRowComposesJustNameAndTitle() {
        let segments = AlertsController.alertsCombinedSegments(
            row: row(entry: entry(label: "Nightly audit", detail: "failed (exit 3)"), isAutomationsRow: true))

        #expect(segments.map(\.kind) == [.name, .separator, .title])
        #expect(segments.map(\.text) == ["Nightly audit", "/", "failed (exit 3)"])
    }
}
