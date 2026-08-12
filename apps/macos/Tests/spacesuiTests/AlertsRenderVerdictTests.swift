import Testing
import workspacecore

@testable import spacesui

/// The verdict that decides whether a refresh of the Alerts pane rebuilds it. Refreshes arrive many
/// times a second while a coding agent streams, and a rebuild replaces every view in the pane, so the
/// verdict is what keeps a click alive: a card destroyed between mouse-down and mouse-up never fires.
@Suite struct AlertsRenderVerdictTests {
    private typealias Signature = AlertsController.AlertsRenderSignature

    private func row(
        attentionID: String = "alert:local:session:s1:bell:t", icon: String = "terminal", iconTint: AppKitController.AlertsIconTint = .terminal,
        shortcut: String = "⌘1", processStatus: RunningProcessState? = nil, agentStatus: AgentWindowStatus? = nil,
        focusRequestKey: String? = "session:ws:s1", hasDetail: Bool = true
    ) -> Signature.Row {
        Signature.Row(
            attentionID: attentionID, icon: icon, iconTint: iconTint, shortcut: shortcut, processStatus: processStatus, agentStatus: agentStatus,
            focusRequestKey: focusRequestKey, hasDetail: hasDetail)
    }

    private func signature(
        rows: [Signature.Row], text: [Signature.RowText], projectName: String = "Project", workspaceName: String = "feature",
        offlineDeviceName: String? = nil
    ) -> Signature {
        Signature(
            groups: [Signature.Group(projectName: projectName, workspaceName: workspaceName, offlineDeviceName: offlineDeviceName, rows: rows)],
            text: text)
    }

    private func text(_ label: String, _ detail: String, attentionID: String = "alert:local:session:s1:bell:t") -> Signature.RowText {
        Signature.RowText(attentionID: attentionID, label: label, detail: detail)
    }

    @Test func aRefreshThatRendersTheSamePaneRendersNothing() {
        let rendered = signature(rows: [row()], text: [text("build box", "vim main.swift")])
        let refreshed = signature(rows: [row()], text: [text("build box", "vim main.swift")])

        #expect(AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: refreshed) == .unchanged)
    }

    /// A bell alert renders its session's live title as the row's detail text, so this is the change that
    /// arrives on every frame of a streaming terminal. It moves strings and nothing else, so the strings
    /// are written into the fields already on screen.
    @Test func aLiveTitleChangeIsTextOnly() {
        let rendered = signature(rows: [row()], text: [text("build box", "vim main.swift")])
        let refreshed = signature(rows: [row()], text: [text("build box", "vim other.swift")])

        #expect(AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: refreshed) == .textOnly)
    }

    /// A row gaining or losing its detail line changes the label's font and the detail field's
    /// visibility, both fixed when the row is built, so it is a change of shape even though only text
    /// moved.
    @Test func aRowGainingItsFirstDetailLineRebuilds() {
        let rendered = signature(rows: [row(hasDetail: false)], text: [text("build box", "")])
        let refreshed = signature(rows: [row(hasDetail: true)], text: [text("build box", "vim main.swift")])

        #expect(AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: refreshed) == .structural)
    }

    @Test func aNewAlertRebuilds() {
        let rendered = signature(rows: [row()], text: [text("build box", "vim main.swift")])
        let refreshed = signature(
            rows: [row(), row(attentionID: "alert:local:process:run-1:t", shortcut: "⌘2", focusRequestKey: "process:ws:run-1")],
            text: [text("build box", "vim main.swift"), text("web", "exited", attentionID: "alert:local:process:run-1:t")])

        #expect(AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: refreshed) == .structural)
    }

    /// Reordering moves each row's window shortcut onto a different alert, so the badges and the
    /// shortcut-to-focus map both have to be rebuilt.
    @Test func reorderingAlertsRebuilds() {
        let first = row()
        let second = row(attentionID: "alert:local:process:run-1:t", shortcut: "⌘2", focusRequestKey: "process:ws:run-1")
        let rendered = signature(rows: [first, second], text: [text("a", ""), text("b", "", attentionID: "alert:local:process:run-1:t")])
        let refreshed = signature(rows: [second, first], text: [text("b", "", attentionID: "alert:local:process:run-1:t"), text("a", "")])

        #expect(AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: refreshed) == .structural)
    }

    /// Each of these decides a view the row builds or a target it acts on, so none may be answered by
    /// writing text.
    @Test func statusIconTintFocusTargetAndOfflineDimmingAllRebuild() {
        let rendered = signature(rows: [row()], text: [text("build box", "vim main.swift")])
        let unchangedText = [text("build box", "vim main.swift")]

        #expect(
            AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: signature(rows: [row(icon: "cpu.fill")], text: unchangedText))
                == .structural)
        #expect(
            AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: signature(rows: [row(iconTint: .warning)], text: unchangedText))
                == .structural)
        #expect(
            AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: signature(rows: [row(agentStatus: .waiting)], text: unchangedText))
                == .structural)
        #expect(
            AlertsController.alertsRenderVerdict(rendered: rendered, refreshed: signature(rows: [row(processStatus: .exited)], text: unchangedText))
                == .structural)
        #expect(
            AlertsController.alertsRenderVerdict(
                rendered: rendered, refreshed: signature(rows: [row(focusRequestKey: "session:ws:s2")], text: unchangedText)) == .structural)
        #expect(
            AlertsController.alertsRenderVerdict(
                rendered: rendered, refreshed: signature(rows: [row()], text: unchangedText, offlineDeviceName: "linux-box")) == .structural)
        #expect(
            AlertsController.alertsRenderVerdict(
                rendered: rendered, refreshed: signature(rows: [row()], text: unchangedText, workspaceName: "renamed")) == .structural)
    }

    /// Nothing has been rendered yet, so there is no pane to leave alone.
    @Test func theFirstRenderOfThePaneIsStructural() {
        #expect(AlertsController.alertsRenderVerdict(rendered: nil, refreshed: signature(rows: [], text: [])) == .structural)
    }
}
