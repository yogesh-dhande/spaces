#if canImport(UIKit)
    import WebKit
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    /// A coding agent's brief on iPhone: which row carries one, when its sheet is up over the agent's
    /// terminal, what the sheet's header says, and what the rendered Markdown shows.
    @MainActor final class AgentBriefTests: XCTestCase {
        private let brief =
            "## Status\n\nRunning the checkout suite.\n\n## Tasks\n\n- [x] Reproduce the 500\n- [ ] Guard the expired session\n- Re-run the suite\n"

        // MARK: - Runtime row

        func testCodingAgentRowCarriesItsBriefAndOtherRowsCarryNone() {
            let agent = SpacesMobileWorkspaceRuntimeRow(
                source: .codingAgent(makeAgentRow(id: "agent-a", activityState: .waiting, brief: brief, briefUpdatedAt: "2026-09-25T10:00:00Z")))
            XCTAssertEqual(agent.brief, brief)
            XCTAssertEqual(agent.briefUpdatedAt, "2026-09-25T10:00:00Z")

            let agentWithoutBrief = SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(makeAgentRow(id: "agent-b", activityState: .spinning)))
            XCTAssertNil(agentWithoutBrief.brief)
            XCTAssertNil(agentWithoutBrief.briefUpdatedAt)

            let process = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    SpacesDeviceWorkspaceProcessRow(
                        id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                        sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)))
            XCTAssertNil(process.brief)
            XCTAssertNil(process.briefUpdatedAt)
        }

        /// A brief is a fact about the row, not a state: an agent keeps the Agents band its activity puts
        /// it in whether or not it has written one.
        func testBriefDoesNotMoveAnAgentBetweenAgentsBands() {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-waiting", activityState: .waiting, brief: brief, briefUpdatedAt: "2026-09-25T10:00:00Z"),
                makeAgentRow(id: "agent-spinning", activityState: .spinning, brief: brief, briefUpdatedAt: "2026-09-25T10:00:00Z"),
                makeAgentRow(id: "agent-done", activityState: .done),
            ])

            let groups = SpacesMobileAgentGrouping.groups(in: overview)

            XCTAssertEqual(groups.map(\.kind), [.blocked, .done, .working])
            XCTAssertEqual(groups.map { $0.entries.map(\.row.id) }, [["agent-waiting"], ["agent-done"], ["agent-spinning"]])
            XCTAssertEqual(groups[0].entries[0].runtimeRow.brief, brief)
        }

        // MARK: - Sheet visibility

        /// An agent the user has not touched opens its brief on entry; dismissing it hides that agent's
        /// brief, and the pill brings it back.
        func testBriefSheetOpensUntilDismissedAndThePillBringsItBack() throws {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", activityState: .waiting, brief: brief)])
            let row = try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-a"))

            XCTAssertTrue(model.agentBriefVisibility.isPresented(for: row), "an agent with a brief the user never hid opens it")

            model.agentBriefVisibility.setPresented(false, for: row)
            XCTAssertFalse(model.agentBriefVisibility.isPresented(for: row), "dismissing the sheet hides that agent's brief")

            model.agentBriefVisibility.setPresented(true, for: row)
            XCTAssertTrue(model.agentBriefVisibility.isPresented(for: row), "the pill brings the brief back")
        }

        func testAgentWithoutBriefPresentsNoSheet() throws {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", activityState: .spinning)])
            let row = try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-a"))

            XCTAssertFalse(model.agentBriefVisibility.isPresented(for: row))
        }

        /// The choice belongs to the agent: hiding one agent's brief leaves another's alone, and it
        /// survives the agent's terminal session changing under it.
        func testHiddenBriefIsKeyedByAgentNotBySession() throws {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-a", activityState: .waiting, brief: brief),
                makeAgentRow(id: "agent-b", activityState: .waiting, brief: brief),
            ])
            model.agentBriefVisibility.setPresented(false, for: try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-a")))

            XCTAssertTrue(model.agentBriefVisibility.isPresented(for: try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-b"))))

            let relaunched = SpacesDeviceWorkspaceCodingAgentRow(
                id: "agent-a", workspaceID: "workspace-feature", name: "claude", command: "claude", agentID: "runtime-agent-a",
                sessionID: "session-relaunched", runState: .running, activityState: .waiting, brief: brief, briefUpdatedAt: nil, canStop: true)
            model.overview = makeOverview(codingAgentRows: [relaunched])
            XCTAssertFalse(model.agentBriefVisibility.isPresented(for: try XCTUnwrap(model.runtimeRow(forSessionID: "session-relaunched"))))
        }

        /// A brief that goes away closes its sheet, and that close is not the user hiding it: the agent's
        /// next brief opens on its own again.
        func testEmptiedBriefClosesTheSheetWithoutHidingTheNextOne() throws {
            let model = makeModel()
            model.overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", activityState: .waiting, brief: brief)])
            XCTAssertTrue(model.agentBriefVisibility.isPresented(for: try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-a"))))

            model.overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", activityState: .waiting)])
            let cleared = try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-a"))
            XCTAssertFalse(model.agentBriefVisibility.isPresented(for: cleared))
            // SwiftUI reports the close of a sheet whose brief went away through the same binding a swipe uses.
            model.agentBriefVisibility.setPresented(false, for: cleared)

            model.overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-a", activityState: .waiting, brief: brief)])
            XCTAssertTrue(model.agentBriefVisibility.isPresented(for: try XCTUnwrap(model.runtimeRow(forSessionID: "session-agent-a"))))
        }

        // MARK: - Sheet header

        func testUpdatedDescriptionReadsRelativeToTheReferenceClock() throws {
            let updated = try XCTUnwrap(SpacesMobileAttention.date(fromISO8601: "2026-09-25T10:00:00Z"))

            let description = try XCTUnwrap(
                TerminalBriefSheet.updatedDescription(briefUpdatedAt: "2026-09-25T10:00:00Z", relativeTo: updated.addingTimeInterval(120)))
            XCTAssertEqual(
                description, "Updated \(AutomationRunFormatting.relativePhrase(for: updated, relativeTo: updated.addingTimeInterval(120)))")
            XCTAssertTrue(description.contains("2"), "two minutes after the write reads as two minutes ago: \(description)")

            // The reference clock advances in 30-second jumps, so it can trail a brief written moments ago.
            XCTAssertEqual(
                TerminalBriefSheet.updatedDescription(briefUpdatedAt: "2026-09-25T10:00:00Z", relativeTo: updated.addingTimeInterval(-5)),
                "Updated just now")
            XCTAssertNil(TerminalBriefSheet.updatedDescription(briefUpdatedAt: nil, relativeTo: updated))
        }

        // MARK: - Rendered document

        /// The brief renders through the Markdown artifact viewer's document: headings and lists as
        /// markup, and `- [ ]`/`- [x]` items as read-only checkboxes that replace their marker text.
        func testBriefDocumentRendersHeadingsListsAndReadOnlyCheckboxes() async throws {
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            let delegate = NavigationFinishDelegate(finished: expectation(description: "brief document loaded"))
            webView.navigationDelegate = delegate
            webView.loadHTMLString(TerminalMarkdownDocument.makeHTML(markdownSource: brief), baseURL: nil)
            await fulfillment(of: [delegate.finished], timeout: 20)

            let headings = try await webView.evaluateJavaScript(
                "Array.from(document.querySelectorAll('#content h2')).map(function (h) { return h.textContent; }).join('|')")
            XCTAssertEqual(headings as? String, "Status|Tasks")

            let items = try await webView.evaluateJavaScript(
                """
                Array.from(document.querySelectorAll('#content li')).map(function (li) {
                  var box = li.querySelector('input[type=checkbox]');
                  var state = box ? (box.checked ? 'checked' : 'open') + (box.disabled ? ',readonly' : ',editable') : 'plain';
                  return state + ':' + li.textContent.trim();
                }).join('|')
                """)
            XCTAssertEqual(items as? String, "checked,readonly:Reproduce the 500|open,readonly:Guard the expired session|plain:Re-run the suite")
        }

        // MARK: - Helpers

        private func makeModel() -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client)
        }
    }

    @MainActor private final class NavigationFinishDelegate: NSObject, WKNavigationDelegate {
        let finished: XCTestExpectation

        init(finished: XCTestExpectation) { self.finished = finished }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished.fulfill() }
    }
#endif
