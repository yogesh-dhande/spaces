import Foundation
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

@Suite struct SessionsPaneModelTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func hit(
        _ key: String, agent: CodingAgent = .claudeCode, project: String = "spaces", projectName: String? = nil, workspace: String = "main",
        title: String = "Title", pinnedName: String? = nil, running: String? = nil, resumability: SpacesDeviceAgentSessionResumability = .resumable,
        ageSeconds: TimeInterval = 600
    ) -> SpacesDeviceAgentSessionHit {
        SpacesDeviceAgentSessionHit(
            agent: agent, sessionKey: key, title: title, workingDirectory: "/work/\(project)",
            lastActive: TerminalSessionTimestamp.fractionalString(from: now.addingTimeInterval(-ageSeconds)), sizeBytes: 4_100_000,
            excerpt: "an excerpt",
            workspace: .init(projectID: project, projectName: projectName ?? project, workspaceID: "w-\(project)", workspaceName: workspace),
            runningTerminalSessionID: running, pinnedName: pinnedName, resumability: resumability)
    }

    private static let idle = SpacesDeviceAgentSessionIndexProgress(indexedSessions: 5, totalSessions: 5, isBuilding: false, isRefreshing: false)

    private static func response(
        _ hits: [SpacesDeviceAgentSessionHit], hasMore: Bool = false, agents: [CodingAgent] = [.claudeCode, .codex],
        projects: [SpacesDeviceAgentSessionProject] = [], progress: SpacesDeviceAgentSessionIndexProgress = idle, pages: Int = 1
    ) -> SessionsPaneModel.Response {
        .init(hits: hits, hasMore: hasMore, availableAgents: agents, availableProjects: projects, progress: progress, pagesFetched: pages)
    }

    private static let harbor = SpacesDeviceAgentSessionProject(id: "harbor", name: "harbor", isHome: false)
    private static let spaces = SpacesDeviceAgentSessionProject(id: "spaces", name: "spaces", isHome: false)
    private static let home = SpacesDeviceAgentSessionProject(id: "home-id", name: "~", isHome: true)

    private func loaded(_ hits: [SpacesDeviceAgentSessionHit], hasMore: Bool = false) -> SessionsPaneModel {
        var model = SessionsPaneModel(deviceID: "local")
        let request = model.beginSearch()
        let applied = model.apply(Self.response(hits, hasMore: hasMore), to: request)
        #expect(applied)
        return model
    }

    // MARK: - Rows

    @Test func rowsKeepTheOrderTheDeviceReturnedEvenWhenProjectsInterleave() {
        let model = loaded([
            Self.hit("1", project: "harbor"), Self.hit("2", project: "spaces"), Self.hit("3", project: "harbor"), Self.hit("4", project: "spaces"),
            Self.hit("5", project: "harbor"),
        ])
        #expect(model.rows(now: Self.now).map(\.key) == ["claudeCode:1", "claudeCode:2", "claudeCode:3", "claudeCode:4", "claudeCode:5"])
    }

    @Test func aRowNamesItsProjectAndWorkspaceAndHomeShowsATilde() {
        #expect(SessionsPaneModel.row(for: Self.hit("1", project: "harbor", workspace: "main"), now: Self.now).placeText == "harbor / main")
        #expect(SessionsPaneModel.row(for: Self.hit("2", project: "home-id", projectName: "~"), now: Self.now).placeText == "~")
    }

    @Test func aPinnedSessionShowsItsPinNameInPlaceOfTheTitle() {
        let row = SessionsPaneModel.row(for: Self.hit("1", title: "Agent title", pinnedName: "Handoff work"), now: Self.now)
        #expect(row.title == "Handoff work")
        #expect(row.isPinned)
        #expect(SessionsPaneModel.row(for: Self.hit("2", title: "Agent title"), now: Self.now).title == "Agent title")
    }

    @Test func aRunningSessionIsMarkedAndAMissingFolderCarriesTheSessionID() {
        #expect(SessionsPaneModel.row(for: Self.hit("1", running: "t1"), now: Self.now).isRunning)
        #expect(SessionsPaneModel.row(for: Self.hit("2"), now: Self.now).isRunning == false)
        #expect(SessionsPaneModel.row(for: Self.hit("3", resumability: .folderMissing), now: Self.now).cannotResumeID == "3")
        #expect(SessionsPaneModel.row(for: Self.hit("4"), now: Self.now).cannotResumeID == nil)
    }

    @Test func theSameKeyUnderTwoAgentsIsTwoRows() {
        let model = loaded([Self.hit("same", agent: .claudeCode), Self.hit("same", agent: .codex)])
        #expect(model.orderedKeys == ["claudeCode:same", "codex:same"])
    }

    // MARK: - Count and progress

    @Test func countShowsAPlusWhileThereAreMorePages() {
        #expect(loaded([Self.hit("1")]).countText == "1 session")
        #expect(loaded([Self.hit("1"), Self.hit("2")]).countText == "2 sessions")
        #expect(loaded([Self.hit("1"), Self.hit("2")], hasMore: true).countText == "2+ sessions")
        #expect(SessionsPaneModel(deviceID: "local").countText == nil)
    }

    @Test func indexingTextShowsOnlyWhileTheFirstBuildRuns() {
        var model = SessionsPaneModel(deviceID: "local")
        let request = model.beginSearch()
        let building = SpacesDeviceAgentSessionIndexProgress(indexedSessions: 120, totalSessions: 400, isBuilding: true, isRefreshing: true)
        _ = model.apply(Self.response([], progress: building), to: request)
        #expect(model.progressText == "Indexing 120 of 400 sessions")
        let refresh = model.beginRefresh()
        let refreshing = SpacesDeviceAgentSessionIndexProgress(indexedSessions: 400, totalSessions: 400, isBuilding: false, isRefreshing: true)
        _ = model.apply(Self.response([], progress: refreshing), to: refresh)
        #expect(model.progressText == nil)
    }

    // MARK: - Paging

    @Test func showMoreAsksForTheNextPageAndAppendsIt() throws {
        var model = loaded([Self.hit("1"), Self.hit("2")], hasMore: true)
        let next = model.beginShowMore()
        let request = try #require(next)
        #expect(request.firstPage == 1)
        #expect(request.pageCount == 1)
        let applied = model.apply(Self.response([Self.hit("3"), Self.hit("4")], hasMore: false), to: request)
        #expect(applied)
        #expect(model.hits.map(\.sessionKey) == ["1", "2", "3", "4"])
        #expect(model.canShowMore == false)
        #expect(model.loadedPages == 2)
    }

    @Test func showMoreSkipsAConversationTheIndexMovedIntoTheNextPage() throws {
        var model = loaded([Self.hit("1"), Self.hit("2")], hasMore: true)
        let next = model.beginShowMore()
        let request = try #require(next)
        _ = model.apply(Self.response([Self.hit("2"), Self.hit("3")]), to: request)
        #expect(model.hits.map(\.sessionKey) == ["1", "2", "3"])
    }

    @Test func showMoreIsUnavailableWhileTheResultsAreBeingReplaced() {
        var model = loaded([Self.hit("1")], hasMore: true)
        #expect(model.canShowMore)
        _ = model.beginSearch()
        #expect(model.canShowMore == false)
        let next = model.beginShowMore()
        #expect(next == nil)
    }

    @Test func aRefreshRereadsEveryLoadedPageAndReplacesTheList() throws {
        var model = loaded([Self.hit("1")], hasMore: true)
        let next = model.beginShowMore()
        let more = try #require(next)
        _ = model.apply(Self.response([Self.hit("2")], hasMore: true), to: more)
        let refresh = model.beginRefresh()
        #expect(refresh.firstPage == 0)
        #expect(refresh.pageCount == 2)
        _ = model.apply(Self.response([Self.hit("0"), Self.hit("1"), Self.hit("2")], hasMore: true, pages: 2), to: refresh)
        #expect(model.hits.map(\.sessionKey) == ["0", "1", "2"])
        #expect(model.loadedPages == 2)
        let third = model.beginShowMore()
        #expect(third?.firstPage == 2)
    }

    // MARK: - Stale responses

    @Test func aResponseToAnEarlierRequestIsDropped() {
        var model = SessionsPaneModel(deviceID: "local")
        let first = model.beginSearch()
        model.query = "newer"
        let second = model.beginSearch()
        let appliedOld = model.apply(Self.response([Self.hit("old")]), to: first)
        #expect(appliedOld == false)
        #expect(model.hits.isEmpty)
        #expect(model.inFlight == second)
        let appliedNew = model.apply(Self.response([Self.hit("new")]), to: second)
        #expect(appliedNew)
        #expect(model.hits.map(\.sessionKey) == ["new"])
    }

    @Test func editingTheQueryLeavesNothingSelectedUntilItsResultsArrive() {
        var model = loaded([Self.hit("old")])
        #expect(model.selectedKey != nil)

        model.query = "newer"
        #expect(model.selectedKey == nil, "Return before the new results arrive must not open the old selection.")
        let search = model.beginSearch()
        _ = model.apply(Self.response([Self.hit("new")]), to: search)
        #expect(model.selectedKey == Self.hit("new").rowKey)
    }

    @Test func aResponseToTheQueryBeforeAnEditCannotReselectOrReplaceResults() {
        var model = loaded([Self.hit("old")])
        let poll = model.beginRefresh()

        model.query = "newer"
        let applied = model.apply(Self.response([Self.hit("old"), Self.hit("older")]), to: poll)

        #expect(applied == false)
        #expect(model.selectedKey == nil)
        #expect(model.inFlight == nil)
    }

    @Test func showMoreIsUnavailableBetweenAQueryEditAndItsSearch() {
        var model = loaded([Self.hit("1")], hasMore: true)
        model.query = "newer"

        #expect(model.canShowMore == false)
        let next = model.beginShowMore()
        #expect(next == nil)
    }

    @Test func aPollThatLosesToASearchIsDropped() {
        var model = loaded([Self.hit("1")])
        let poll = model.beginRefresh()
        let search = model.beginSearch()
        let appliedPoll = model.apply(Self.response([Self.hit("stale")]), to: poll)
        let failedPoll = model.fail("boom", for: poll)
        #expect(appliedPoll == false)
        #expect(failedPoll == false)
        #expect(model.errorMessage == nil)
        #expect(model.inFlight == search)
    }

    @Test func clearingTheResultsDropsAResponseStillOnItsWay() {
        var model = SessionsPaneModel(deviceID: "local")
        let request = model.beginSearch()
        model.clearResults()
        let applied = model.apply(Self.response([Self.hit("1")]), to: request)
        #expect(applied == false)
        #expect(model.needsSearch)
    }

    @Test func switchingDeviceDropsTheOldDevicesResultsAndResponses() {
        var model = SessionsPaneModel(deviceID: "local")
        let request = model.beginSearch()
        _ = model.apply(Self.response([Self.hit("1")]), to: request)
        let pending = model.beginRefresh()
        model.selectDevice("remote")
        #expect(model.hits.isEmpty)
        #expect(model.progress == nil)
        let applied = model.apply(Self.response([Self.hit("1")]), to: pending)
        #expect(applied == false)
    }

    @Test func aFailedSearchClearsTheListButAFailedRefreshKeepsIt() {
        var model = loaded([Self.hit("1")])
        let refresh = model.beginRefresh()
        let refreshFailed = model.fail("down", for: refresh)
        #expect(refreshFailed)
        #expect(model.hits.count == 1)
        #expect(model.errorMessage == "down")
        let search = model.beginSearch()
        let searchFailed = model.fail("down", for: search)
        #expect(searchFailed)
        #expect(model.hits.isEmpty)
        #expect(model.needsSearch == false)
    }

    // MARK: - Polling

    @Test func pollingRunsOnlyWhileTheDeviceIsBuildingOrRefreshing() {
        func progress(building: Bool, refreshing: Bool) -> SpacesDeviceAgentSessionIndexProgress {
            .init(indexedSessions: 1, totalSessions: 2, isBuilding: building, isRefreshing: refreshing)
        }
        #expect(SessionsPaneModel.shouldPoll(progress: nil) == false)
        #expect(SessionsPaneModel.shouldPoll(progress: progress(building: false, refreshing: false)) == false)
        #expect(SessionsPaneModel.shouldPoll(progress: progress(building: true, refreshing: false)))
        #expect(SessionsPaneModel.shouldPoll(progress: progress(building: false, refreshing: true)))
        var model = SessionsPaneModel(deviceID: "local")
        #expect(model.shouldPoll == false)
        let request = model.beginSearch()
        _ = model.apply(Self.response([], progress: progress(building: true, refreshing: true)), to: request)
        #expect(model.shouldPoll)
    }

    // MARK: - Agent filter

    @Test func agentSelectionIsRememberedPerDevice() {
        var model = SessionsPaneModel(deviceID: "local")
        #expect(model.agentsTitle == "All agents")
        #expect(model.requestAgents == nil)
        model.toggleAgent(.codex)
        model.toggleAgent(.claudeCode)
        #expect(model.selectedAgents == [.claudeCode, .codex])
        #expect(model.agentsTitle == "Claude Code, Codex")
        #expect(model.requestAgents == [.claudeCode, .codex])

        model.selectDevice("remote")
        #expect(model.agentsTitle == "All agents")
        model.toggleAgent(.pi)
        #expect(model.selectedAgents == [.pi])

        model.selectDevice("local")
        #expect(model.selectedAgents == [.claudeCode, .codex])
        model.toggleAgent(.codex)
        model.toggleAgent(.claudeCode)
        #expect(model.agentsTitle == "All agents")
        model.selectDevice("remote")
        #expect(model.selectedAgents == [.pi])
    }

    @Test func clearingTheAgentsReturnsToAllAgents() {
        var model = SessionsPaneModel(deviceID: "local")
        model.toggleAgent(.amp)
        model.clearAgents()
        #expect(model.selectedAgents.isEmpty)
        #expect(model.agentsByDevice.isEmpty)
    }

    @Test func aSearchCarriesTheCurrentDevicesFilterAndQuery() {
        var model = SessionsPaneModel(deviceID: "remote", agentsByDevice: ["remote": [.opencode]])
        model.query = "handoff"
        let request = model.beginSearch()
        #expect(request.deviceID == "remote")
        #expect(request.agents == [.opencode])
        #expect(request.query == "handoff")
        #expect(request.firstPage == 0)
    }

    @Test func storedSelectionsRoundTripAndDropAgentsThisBuildDoesNotKnow() {
        let selections: [String: [CodingAgent]] = ["a": [.claudeCode, .codex], "b": [.amp]]
        #expect(SessionsPaneModel.decodeAgentSelections(SessionsPaneModel.encodeAgentSelections(selections)) == selections)
        #expect(SessionsPaneModel.decodeAgentSelections(#"{"a":["codex","futureAgent"],"b":["futureAgent"]}"#) == ["a": [.codex]])
        #expect(SessionsPaneModel.decodeAgentSelections("not json").isEmpty)
        #expect(SessionsPaneModel.decodeAgentSelections(nil).isEmpty)
    }

    // MARK: - Project filter

    @Test func theProjectFilterGoesIntoTheRequest() {
        var model = SessionsPaneModel(deviceID: "local")
        #expect(model.beginSearch().projectID == nil)
        model.selectProject("harbor")
        #expect(model.beginSearch().projectID == "harbor")
        #expect(model.beginRefresh().projectID == "harbor")
        model.selectProject(nil)
        #expect(model.beginSearch().projectID == nil)
    }

    @Test func changingTheProjectDropsTheSelectionAndTheResponsesOnTheirWay() {
        var model = loaded([Self.hit("1", project: "harbor")])
        #expect(model.selectedKey != nil)
        let pending = model.beginRefresh()

        model.selectProject("spaces")
        #expect(model.selectedKey == nil, "Return before the new results arrive must not open the old selection.")
        #expect(model.canShowMore == false)
        let applied = model.apply(Self.response([Self.hit("1", project: "harbor")], projects: [Self.harbor, Self.spaces]), to: pending)
        #expect(applied == false)

        let search = model.beginSearch()
        #expect(search.firstPage == 0)
        _ = model.apply(Self.response([Self.hit("2", project: "spaces")], projects: [Self.harbor, Self.spaces]), to: search)
        #expect(model.hits.map(\.sessionKey) == ["2"])
        #expect(model.selectedKey == "claudeCode:2")
    }

    @Test func theProjectFilterIsRememberedPerDeviceAndRestored() {
        var model = SessionsPaneModel(deviceID: "local")
        model.selectProject("harbor")
        model.selectDevice("remote")
        #expect(model.selectedProjectID == nil)
        model.selectProject("spaces")
        model.selectDevice("local")
        #expect(model.selectedProjectID == "harbor")

        let restored = SessionsPaneModel(
            deviceID: "remote",
            projectByDevice: SessionsPaneModel.decodeProjectSelections(SessionsPaneModel.encodeProjectSelections(model.projectByDevice)))
        #expect(restored.selectedProjectID == "spaces")
        #expect(SessionsPaneModel.decodeProjectSelections("not json").isEmpty)
        #expect(SessionsPaneModel.decodeProjectSelections(nil).isEmpty)
    }

    @Test func aRememberedProjectTheDeviceDoesNotListIsDroppedAndTheSearchRepeatsOnce() {
        var model = SessionsPaneModel(deviceID: "local", projectByDevice: ["local": "deleted"])
        let first = model.beginSearch()
        #expect(first.projectID == "deleted")
        let applied = model.apply(Self.response([], projects: [Self.spaces, Self.home]), to: first)
        #expect(applied)
        #expect(model.selectedProjectID == nil)
        #expect(model.needsSearch, "The pane must search again without the dropped project.")

        let second = model.beginSearch()
        #expect(second.projectID == nil)
        _ = model.apply(Self.response([Self.hit("1")], projects: [Self.spaces, Self.home]), to: second)
        #expect(model.needsSearch == false)
        #expect(model.hits.map(\.sessionKey) == ["1"])
        #expect(model.availableProjects == [Self.spaces, Self.home])
    }

    @Test func aListedRememberedProjectIsKept() {
        var model = SessionsPaneModel(deviceID: "local", projectByDevice: ["local": "spaces"])
        let request = model.beginSearch()
        _ = model.apply(Self.response([Self.hit("1")], projects: [Self.spaces, Self.home]), to: request)
        #expect(model.selectedProjectID == "spaces")
        #expect(model.needsSearch == false)
    }

    // MARK: - Device on open

    @Test func opensOnTheLastSearchedDeviceWhileItIsPairedElseThisMac() {
        #expect(SessionsPaneModel.initialDeviceID(lastSearched: "remote", pairedDeviceIDs: ["local", "remote"], localDeviceID: "local") == "remote")
        #expect(SessionsPaneModel.initialDeviceID(lastSearched: "gone", pairedDeviceIDs: ["local", "remote"], localDeviceID: "local") == "local")
        #expect(SessionsPaneModel.initialDeviceID(lastSearched: nil, pairedDeviceIDs: ["local", "remote"], localDeviceID: "local") == "local")
    }

    // MARK: - Selection

    @Test func theFirstRowIsSelectedWhenResultsArrive() { #expect(loaded([Self.hit("1"), Self.hit("2")]).selectedKey == "claudeCode:1") }

    @Test func arrowsWalkTheRowsInDisplayOrderAndStopAtTheEnds() {
        var model = loaded([Self.hit("1", project: "a"), Self.hit("2", project: "b"), Self.hit("3", project: "a")])
        #expect(model.orderedKeys == ["claudeCode:1", "claudeCode:2", "claudeCode:3"])
        model.moveSelection(by: 1)
        #expect(model.selectedKey == "claudeCode:2")
        model.moveSelection(by: 1)
        model.moveSelection(by: 1)
        #expect(model.selectedKey == "claudeCode:3")
        model.moveSelection(by: -1)
        #expect(model.selectedKey == "claudeCode:2")
    }

    @Test func theSelectionStaysOnItsRowWhenAPollReordersTheList() {
        var model = loaded([Self.hit("1"), Self.hit("2")])
        model.select("claudeCode:2")
        let refresh = model.beginRefresh()
        _ = model.apply(Self.response([Self.hit("0"), Self.hit("1"), Self.hit("2")]), to: refresh)
        #expect(model.selectedKey == "claudeCode:2")
        let search = model.beginSearch()
        _ = model.apply(Self.response([Self.hit("9")]), to: search)
        #expect(model.selectedKey == "claudeCode:9")
    }

    // MARK: - Resuming

    @Test func onlyOneResumeRunsAtATimeAndAFailureIsKeptOnItsRow() {
        var model = loaded([Self.hit("1"), Self.hit("2")])
        let first = model.beginResume(key: "claudeCode:1")
        let second = model.beginResume(key: "claudeCode:2")
        #expect(first)
        #expect(second == false)
        model.finishResume(key: "claudeCode:1", errorMessage: "Working directory no longer exists")
        #expect(model.resumingKey == nil)
        #expect(model.resumeError == .init(key: "claudeCode:1", message: "Working directory no longer exists"))
        let third = model.beginResume(key: "claudeCode:2")
        #expect(third)
        #expect(model.resumeError == nil)
    }

    // MARK: - Formatting

    @Test func ageReadsAsMinutesHoursYesterdayThenDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // 2027-01-15 08:00:00 UTC
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ secondsAgo: TimeInterval) -> String {
            SessionRowFormatting.ageText(
                lastActive: TerminalSessionTimestamp.fractionalString(from: now.addingTimeInterval(-secondsAgo)), now: now, calendar: calendar,
                locale: locale)
        }
        #expect(age(20) == "Just now")
        #expect(age(12 * 60) == "12 min ago")
        #expect(age(3 * 3600) == "3 hr ago")
        #expect(age(10 * 3600) == "Yesterday")
        #expect(age(40 * 3600) == "Jan 13")
        #expect(age(60 * 86400) == "Nov 16, 2026")
        #expect(SessionRowFormatting.ageText(lastActive: "garbage", now: now, calendar: calendar, locale: locale) == "")
    }

    @Test func sizeUsesFileStyleUnits() {
        #expect(SessionRowFormatting.sizeText(bytes: 4_100_000) == "4.1 MB")
        #expect(SessionRowFormatting.sizeText(bytes: 640_000) == "640 KB")
    }
}
