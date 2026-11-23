#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    private func makeHit(
        _ key: String, agent: CodingAgent = .claudeCode, title: String = "Title", excerpt: String? = nil,
        resumability: SpacesDeviceAgentSessionResumability = .resumable, running: String? = nil, pinnedName: String? = nil,
        project: String = "spaces", workspace: String = "main"
    ) -> SpacesDeviceAgentSessionHit {
        SpacesDeviceAgentSessionHit(
            agent: agent, sessionKey: key, title: title, workingDirectory: "/tmp/\(key)", lastActive: "2026-11-18T10:00:00.000Z",
            sizeBytes: 4_200_000, excerpt: excerpt,
            workspace: SpacesDeviceAgentSessionWorkspace(projectID: "p", projectName: project, workspaceID: "w", workspaceName: workspace),
            runningTerminalSessionID: running, pinnedName: pinnedName, resumability: resumability)
    }

    private func makeResult(
        _ hits: [SpacesDeviceAgentSessionHit], hasMore: Bool = false, available: [CodingAgent] = [.claudeCode, .codex],
        projects: [SpacesDeviceAgentSessionProject] = [],
        progress: SpacesDeviceAgentSessionIndexProgress = .init(indexedSessions: 5, totalSessions: 5, isBuilding: false, isRefreshing: false)
    ) -> SpacesDeviceAgentSessionSearchResult {
        SpacesDeviceAgentSessionSearchResult(
            results: hits, hasMore: hasMore, availableAgents: available, availableProjects: projects, progress: progress)
    }

    private let projectChoices = [
        SpacesDeviceAgentSessionProject(id: "p1", name: "harbor", isHome: false),
        SpacesDeviceAgentSessionProject(id: "p2", name: "lantern", isHome: false),
        SpacesDeviceAgentSessionProject(id: "home", name: "~", isHome: true),
    ]

    final class SessionSearchHighlightTests: XCTestCase {
        private func highlighted(_ text: String, _ query: String) -> [String] {
            SessionSearchHighlight.ranges(in: text, query: query).map { String(text[$0]) }
        }

        func testWordsMatchAsCaseAndDiacriticInsensitivePrefixes() {
            XCTAssertEqual(highlighted("The Cafe handoff permissions", "caf PERMISS"), ["Caf", "permiss"])
            XCTAssertEqual(highlighted("Un café noir", "cafe"), ["café"])
        }

        func testAPrefixOnlyMatchesTheStartOfAWord() { XCTAssertEqual(highlighted("reshape the shape", "shape"), ["shape"]) }

        func testAQuotedPhraseIsOneUnit() {
            XCTAssertEqual(highlighted("stale permission record, permission was stale", "\"stale permission\""), ["stale permission"])
            XCTAssertEqual(highlighted("permission only", "\"stale permission\""), [])
        }

        func testOverlappingTermsMergeAndBlankQueriesHighlightNothing() {
            XCTAssertEqual(highlighted("handoff", "hand handoff"), ["handoff"])
            XCTAssertEqual(highlighted("anything", "  "), [])
        }
    }

    final class SessionSearchPreferencesTests: XCTestCase {
        private var suite: String!
        private var defaults: UserDefaults!

        override func setUp() {
            super.setUp()
            suite = "session-search-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)
        }

        override func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            super.tearDown()
        }

        func testInitialDevicePrefersTheLastSearchedThenTheActiveDevice() {
            let paired = ["a", "b", "c"]
            XCTAssertEqual(SessionSearchPreferences.initialDeviceID(lastSearched: "c", activeDeviceID: "b", pairedDeviceIDs: paired), "c")
            XCTAssertEqual(SessionSearchPreferences.initialDeviceID(lastSearched: "gone", activeDeviceID: "b", pairedDeviceIDs: paired), "b")
            XCTAssertEqual(SessionSearchPreferences.initialDeviceID(lastSearched: nil, activeDeviceID: nil, pairedDeviceIDs: paired), "a")
            XCTAssertNil(SessionSearchPreferences.initialDeviceID(lastSearched: "a", activeDeviceID: "a", pairedDeviceIDs: []))
        }

        func testAgentChoicesAreRememberedPerDevice() {
            let preferences = SessionSearchPreferences(defaults: defaults)
            preferences.setAgents([.codex, .amp], forDeviceID: "a")
            preferences.setAgents([.pi], forDeviceID: "b")

            XCTAssertEqual(SessionSearchPreferences(defaults: defaults).agents(forDeviceID: "a"), [.codex, .amp])
            XCTAssertEqual(SessionSearchPreferences(defaults: defaults).agents(forDeviceID: "b"), [.pi])
            preferences.setAgents([], forDeviceID: "a")
            XCTAssertEqual(preferences.agents(forDeviceID: "a"), [])
            XCTAssertEqual(preferences.agents(forDeviceID: "b"), [.pi])
        }
    }

    @MainActor final class SessionSearchModelTests: XCTestCase {
        private var suite: String!
        private var defaults: UserDefaults!
        private var offline: Set<String> = []
        private var requests: [(deviceID: String, request: SpacesDeviceAgentSessionSearchRequest)] = []
        private var resumed: [String] = []
        private var searchHandler: (String, SpacesDeviceAgentSessionSearchRequest) async throws -> SpacesDeviceAgentSessionSearchResult = { _, _ in
            makeResult([])
        }
        private var resumeOutcome: SessionSearchResumeOutcome = .failed("unset")

        override func setUp() {
            super.setUp()
            suite = "session-search-model-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)
        }

        override func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            super.tearDown()
        }

        private func makeModel(devices: [String] = ["mac", "linux"], active: String? = "mac") -> SessionSearchModel {
            SessionSearchModel(
                environment: SessionSearchEnvironment(
                    devices: { devices.map { SessionSearchDevice(id: $0, name: "Device \($0)") } }, activeDeviceID: { active },
                    isOffline: { [unowned self] in offline.contains($0) },
                    search: { [unowned self] deviceID, request in
                        requests.append((deviceID, request))
                        return try await searchHandler(deviceID, request)
                    },
                    resume: { [unowned self] _, hit in
                        resumed.append(hit.sessionKey)
                        return resumeOutcome
                    }), preferences: SessionSearchPreferences(defaults: defaults), debounce: .milliseconds(20))
        }

        func testOpensOnTheActiveDeviceThenOnTheLastSearchedOne() async {
            let first = makeModel()
            XCTAssertEqual(first.deviceID, "mac")
            await first.selectDevice("linux")

            XCTAssertEqual(makeModel().deviceID, "linux")
        }

        func testSearchingTheActiveDeviceRemembersItAfterTheActiveDeviceChanges() async {
            await makeModel(active: "linux").reload()

            XCTAssertEqual(makeModel(active: "mac").deviceID, "linux")
        }

        func testNextPageAppendsAndSkipsConversationsAShiftedPageRepeats() async {
            searchHandler = { _, request in
                request.page == 0
                    ? makeResult([makeHit("a"), makeHit("b")], hasMore: true) : makeResult([makeHit("b"), makeHit("c")], hasMore: false)
            }
            let model = makeModel()
            await model.reload()
            XCTAssertEqual(model.hits.map(\.sessionKey), ["a", "b"])
            XCTAssertTrue(model.results.hasMore)

            await model.showMore()

            XCTAssertEqual(model.hits.map(\.sessionKey), ["a", "b", "c"])
            XCTAssertFalse(model.results.hasMore)
            XCTAssertEqual(requests.map(\.request.page), [0, 1])
        }

        func testAFailedSearchForANewQueryDropsTheOldPagesSoShowMoreCannotMixThem() async {
            searchHandler = { _, request in
                if request.query == "b" { throw SpacesDeviceAPIClientError.requestFailed("down", code: nil) }
                return makeResult([makeHit("a-\(request.page)")], hasMore: true)
            }
            let model = makeModel()
            model.query = "a"
            await model.reload()
            model.query = "b"
            await model.reload()

            XCTAssertTrue(model.hits.isEmpty)
            XCTAssertFalse(model.results.hasMore)
            let before = requests.count
            await model.showMore()
            XCTAssertEqual(requests.count, before)
        }

        func testAFailedSearchForANewAgentFilterDropsTheOldPages() async {
            searchHandler = { _, request in
                if request.agents == [.codex] { throw SpacesDeviceAPIClientError.requestFailed("down", code: nil) }
                return makeResult([makeHit("a-\(request.page)")], hasMore: true)
            }
            let model = makeModel()
            await model.reload()
            await model.toggleAgent(.codex)

            XCTAssertTrue(model.hits.isEmpty)
            XCTAssertFalse(model.results.hasMore)
        }

        func testShowMoreIsIgnoredBetweenAQueryEditAndItsSearch() async {
            searchHandler = { _, request in makeResult([makeHit("a-\(request.page)")], hasMore: true) }
            let model = makeModel()
            await model.reload()
            model.query = "b"
            let before = requests.count

            await model.showMore()

            XCTAssertEqual(requests.count, before)
            XCTAssertEqual(model.hits.map(\.sessionKey), ["a-0"])
        }

        func testARememberedAgentTheDeviceHasNothingFromIsReplacedByASearchOfAllAgents() async {
            SessionSearchPreferences(defaults: defaults).setAgents([.codex], forDeviceID: "mac")
            searchHandler = { _, request in
                request.agents == [.codex] ? makeResult([], available: [.claudeCode]) : makeResult([makeHit("c")], available: [.claudeCode])
            }
            let model = makeModel()
            await model.reload()

            XCTAssertEqual(requests.map(\.request.agents), [[.codex], nil], "The filter shown must be the filter searched, asked once more.")
            XCTAssertEqual(model.effectiveAgents, [])
            XCTAssertEqual(model.hits.map(\.sessionKey), ["c"])
        }

        func testAStaleResponseNeverOverwritesANewerSearch() async {
            let (gate, release) = AsyncStream<Void>.makeStream()
            searchHandler = { _, request in
                if request.query == "old" {
                    for await _ in gate { break }
                    return makeResult([makeHit("old")])
                }
                return makeResult([makeHit("new")])
            }
            let model = makeModel()
            model.query = "old"
            let slow = Task { await model.reload() }
            while requests.isEmpty { await Task.yield() }
            model.query = "new"
            await model.reload()
            release.yield()
            await slow.value

            XCTAssertEqual(model.hits.map(\.sessionKey), ["new"])
        }

        func testTypingSearchesOnceAfterTheDebounce() async throws {
            searchHandler = { _, request in makeResult([makeHit(request.query)]) }
            let model = makeModel()
            for text in ["h", "ha", "han"] {
                model.query = text
                model.queryChanged()
            }
            try await Task.sleep(for: .milliseconds(200))

            XCTAssertEqual(requests.map(\.request.query), ["han"])
            XCTAssertEqual(model.hits.map(\.sessionKey), ["han"])
        }

        func testATypedSearchIsNotCancelledByItsOwnDebounce() async throws {
            // A real transport throws when its task is cancelled, which is what exposed a search cancelling itself.
            searchHandler = { _, request in
                try await Task.sleep(for: .milliseconds(30))
                return makeResult([makeHit(request.query)])
            }
            let model = makeModel()
            model.query = "han"
            model.queryChanged()
            try await Task.sleep(for: .milliseconds(300))

            XCTAssertEqual(model.hits.map(\.sessionKey), ["han"])
            XCTAssertNil(model.searchError)
            XCTAssertFalse(model.isLoading)
        }

        func testShowMoreWorksAfterTheQueryChangesWhileAPageWasLoading() async {
            let (gate, release) = AsyncStream<Void>.makeStream()
            var gatedPages = 0
            searchHandler = { _, request in
                if request.page == 1 {
                    gatedPages += 1
                    if gatedPages == 1 { for await _ in gate { break } }
                    return makeResult([makeHit("page-\(gatedPages)")])
                }
                return makeResult([makeHit(request.query)], hasMore: true)
            }
            let model = makeModel()
            model.query = "one"
            await model.reload()
            let more = Task { await model.showMore() }
            while requests.count < 2 { await Task.yield() }
            XCTAssertTrue(model.isLoadingMore)

            model.query = "two"
            await model.reload()
            XCTAssertFalse(model.isLoadingMore, "A new search discards the page that was loading.")
            release.yield()
            await more.value

            await model.showMore()
            XCTAssertEqual(model.hits.map(\.sessionKey), ["two", "page-2"])
        }

        func testAgentChoiceIsSentRememberedPerDeviceAndLimitedToAvailableAgents() async {
            searchHandler = { _, _ in makeResult([], available: [.claudeCode, .codex]) }
            let model = makeModel()
            await model.reload()
            XCTAssertNil(requests.last?.request.agents, "No choice searches every agent.")

            await model.toggleAgent(.codex)
            XCTAssertEqual(requests.last?.request.agents, [.codex])

            await model.selectDevice("linux")
            XCTAssertNil(requests.last?.request.agents, "Another device starts with its own choice.")
            await model.selectDevice("mac")
            XCTAssertEqual(model.selectedAgents, [.codex])
            XCTAssertEqual(requests.last?.request.agents, [.codex])

            searchHandler = { _, _ in makeResult([], available: [.claudeCode]) }
            await model.reload()
            XCTAssertEqual(model.effectiveAgents, [], "A remembered agent the device no longer has is not applied.")
        }

        func testTheProjectIsSentAndChangingItSearchesFromPageZero() async {
            searchHandler = { _, request in makeResult([makeHit("a-\(request.page)")], hasMore: true, projects: projectChoices) }
            let model = makeModel()
            await model.reload()
            XCTAssertNil(requests.last?.request.projectID, "No choice searches every project.")
            await model.showMore()
            XCTAssertEqual(requests.last?.request.page, 1)

            await model.selectProject("p2")

            XCTAssertEqual(requests.last?.request.projectID, "p2")
            XCTAssertEqual(requests.last?.request.page, 0)
            XCTAssertEqual(model.hits.map(\.sessionKey), ["a-0"])
            XCTAssertEqual(model.effectiveProject?.name, "lantern")

            await model.selectProject(nil)
            XCTAssertNil(requests.last?.request.projectID)
            XCTAssertNil(model.effectiveProject)
        }

        func testTheProjectChoiceIsRememberedPerDeviceAndRestored() async {
            searchHandler = { _, _ in makeResult([], projects: projectChoices) }
            let model = makeModel()
            await model.reload()
            await model.selectProject("p1")

            await model.selectDevice("linux")
            XCTAssertNil(model.selectedProjectID, "Another device starts with its own choice.")
            XCTAssertNil(requests.last?.request.projectID)
            await model.selectDevice("mac")
            XCTAssertEqual(requests.last?.request.projectID, "p1")

            let reopened = makeModel()
            XCTAssertEqual(reopened.selectedProjectID, "p1")
            await reopened.reload()
            XCTAssertEqual(requests.last?.request.projectID, "p1")
        }

        func testARememberedProjectTheDeviceNoLongerListsIsDroppedAndTheSearchRepeatedOnce() async {
            SessionSearchPreferences(defaults: defaults).setProjectID("gone", forDeviceID: "mac")
            searchHandler = { _, request in
                request.projectID == "gone" ? makeResult([], projects: projectChoices) : makeResult([makeHit("c")], projects: projectChoices)
            }
            let model = makeModel()
            await model.reload()

            XCTAssertEqual(requests.map(\.request.projectID), ["gone", nil], "The filter shown must be the filter searched, asked once more.")
            XCTAssertNil(model.effectiveProjectID)
            XCTAssertEqual(model.hits.map(\.sessionKey), ["c"])
        }

        func testALateAnswerForThePreviousProjectIsIgnored() async {
            let (gate, release) = AsyncStream<Void>.makeStream()
            searchHandler = { _, request in
                if request.projectID == "p1" {
                    for await _ in gate { break }
                    return makeResult([makeHit("p1-hit")], projects: projectChoices)
                }
                return makeResult([makeHit("p2-hit")], projects: projectChoices)
            }
            let model = makeModel()
            let slow = Task { await model.selectProject("p1") }
            while requests.isEmpty { await Task.yield() }
            await model.selectProject("p2")
            release.yield()
            await slow.value

            XCTAssertEqual(model.hits.map(\.sessionKey), ["p2-hit"])
            XCTAssertEqual(model.effectiveProjectID, "p2")
        }

        func testPollingFollowsTheIndexStatusAndKeepsPagesTheUserLoaded() async {
            var building = true
            searchHandler = { _, request in
                makeResult(
                    request.page == 0 ? [makeHit(building ? "partial" : "full")] : [makeHit("page2")], hasMore: request.page == 0,
                    progress: .init(indexedSessions: 3, totalSessions: 9, isBuilding: building, isRefreshing: false))
            }
            let model = makeModel()
            await model.reload()
            XCTAssertTrue(model.needsPolling)
            XCTAssertTrue(model.isIndexBuilding)

            await model.showMore()
            building = false
            await model.poll()

            XCTAssertFalse(model.needsPolling)
            XCTAssertEqual(model.hits.map(\.sessionKey), ["partial", "page2"], "A poll leaves a list with later pages alone.")
        }

        /// Answers request `n` (in the order the model sends them) only once the matching gate is released.
        private func gateRequests(_ gated: Set<Int>) -> [Int: AsyncStream<Void>.Continuation] {
            var releases: [Int: AsyncStream<Void>.Continuation] = [:]
            var gates: [Int: AsyncStream<Void>] = [:]
            for index in gated {
                let (gate, release) = AsyncStream<Void>.makeStream()
                gates[index] = gate
                releases[index] = release
            }
            searchHandler = { [unowned self] _, request in
                let index = requests.count - 1
                if let gate = gates[index] { for await _ in gate { break } }
                if request.page == 0 { return makeResult([makeHit(index == 0 ? "a" : "polled")], hasMore: true) }
                return makeResult([makeHit("b")])
            }
            return releases
        }

        func testAPollStartedWhileAPageLoadsDoesNotReplaceTheListWhenItAnswersLater() async {
            let releases = gateRequests([1, 2])
            let model = makeModel()
            await model.reload()
            let more = Task { await model.showMore() }
            while requests.count < 2 { await Task.yield() }
            let poll = Task { await model.poll() }
            while requests.count < 3 { await Task.yield() }

            releases[1]?.yield()
            await more.value
            XCTAssertEqual(model.hits.map(\.sessionKey), ["a", "b"])
            releases[2]?.yield()
            await poll.value

            XCTAssertEqual(model.hits.map(\.sessionKey), ["a", "b"], "The poll's first page must not collapse the pages the user loaded.")
        }

        func testAPollThatAnswersAfterAPageWasAppendedDoesNotReplaceTheList() async {
            let releases = gateRequests([1])
            let model = makeModel()
            await model.reload()
            let poll = Task { await model.poll() }
            while requests.count < 2 { await Task.yield() }

            await model.showMore()
            XCTAssertEqual(model.hits.map(\.sessionKey), ["a", "b"])
            releases[1]?.yield()
            await poll.value

            XCTAssertEqual(model.hits.map(\.sessionKey), ["a", "b"])
        }

        func testAnOfflineDeviceShowsNoResultsAndSendsNoRequest() async {
            searchHandler = { _, _ in makeResult([makeHit("a")]) }
            let model = makeModel()
            await model.reload()
            XCTAssertEqual(model.hits.count, 1)

            offline = ["mac"]
            requests = []
            await model.reload()

            XCTAssertTrue(model.isDeviceOffline)
            XCTAssertTrue(model.hits.isEmpty)
            XCTAssertTrue(requests.isEmpty)
            XCTAssertFalse(model.needsPolling)
        }

        func testASearchFailureIsShownInline() async {
            searchHandler = { _, _ in throw SpacesDeviceAPIClientError.requestFailed("The index is unavailable.", code: nil) }
            let model = makeModel()
            await model.reload()

            XCTAssertEqual(model.searchError, "The index is unavailable.")
        }

        func testAFolderMissingConversationIsNeverResumed() async {
            let model = makeModel()
            let opened = await model.resume(makeHit("gone", resumability: .folderMissing))

            XCTAssertNil(opened)
            XCTAssertTrue(resumed.isEmpty)
        }

        func testAFailedResumeIsReportedOnItsRowAndASuccessfulOneReturnsTheTerminal() async {
            let model = makeModel()
            let hit = makeHit("a")
            resumeOutcome = .failed("Working directory no longer exists")
            let failed = await model.resume(hit)

            XCTAssertNil(failed)
            XCTAssertEqual(model.resumeFailure, SessionSearchModel.ResumeFailure(hitID: hit.listID, message: "Working directory no longer exists"))

            resumeOutcome = .opened(
                SpacesDeviceTerminalSessionSummary(
                    id: "t1", title: "terminal", workingDirectory: "/tmp/work", shell: "/bin/zsh", command: nil, state: .running,
                    backend: .ghosttyEmbedded, lifetimePolicy: .persistent, servicePID: 100, childPID: 200, workspaceID: "workspace-1",
                    workspaceTitle: nil, projectID: nil, projectName: nil, createdAt: "2026-07-28T00:00:00Z", updatedAt: "2026-07-28T00:00:01Z",
                    isControlAvailable: true, isSubscriptionAvailable: true, attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
                    rowKind: .process, rowSourceID: "process-row", hasFinalRender: false))
            let opened = await model.resume(hit)
            XCTAssertEqual(opened?.deviceID, "mac")
            XCTAssertEqual(opened?.session.id, "t1")
            XCTAssertNil(model.resumeFailure)
        }

        func testRowTextShowsLocationAgeSizeAndRunning() {
            let now = TerminalSessionTimestamp.date(from: "2026-11-18T10:12:00.000Z")!
            let running = makeHit("a", running: "t1")

            let meta = SessionSearchRowText.meta(of: running, relativeTo: now)
            XCTAssertTrue(meta.hasPrefix("spaces / main · 12m · "), meta)
            XCTAssertTrue(meta.hasSuffix(" · Running"), meta)
            XCTAssertFalse(SessionSearchRowText.meta(of: makeHit("b"), relativeTo: now).contains("Running"))
            XCTAssertEqual(SessionSearchRowText.location(of: makeHit("h", project: "~", workspace: "~")), "~")
            XCTAssertEqual(SessionSearchRowText.folderMissing(sessionKey: "abc"), "Folder no longer exists, can't resume · id abc")
            XCTAssertEqual(SessionSearchRowText.agentsSummary([]), "All agents")
            XCTAssertEqual(SessionSearchRowText.agentsSummary([.codex, .claudeCode]), "Claude Code, Codex")
        }

        func testStatusLineCountsLoadedSessionsAndMarksMorePages() {
            XCTAssertEqual(SessionSearchRowText.countSummary(loaded: 20, hasMore: true), "20+ sessions")
            XCTAssertEqual(SessionSearchRowText.countSummary(loaded: 7, hasMore: false), "7 sessions")
            XCTAssertEqual(SessionSearchRowText.countSummary(loaded: 1, hasMore: false), "1 session")
        }

        // MARK: - Demo backend

        func testSheetModelLoadsTheDemoSeedAndFiltersByAgent() async throws {
            let app = SpacesMobileAppModel()
            app.setDemoMode(true)
            defer { app.setDemoMode(false) }
            let model = app.makeSessionSearchModel()
            XCTAssertEqual(model.deviceID, SpacesMobileDemoDevice.id)

            await model.reload()
            XCTAssertEqual(model.hits.count, DemoAgentSessionSearch.defaultSeeds.count)
            XCTAssertEqual(model.availableAgents, CodingAgent.allCases)

            await model.toggleAgent(.codex)
            XCTAssertFalse(model.hits.isEmpty)
            XCTAssertTrue(model.hits.allSatisfy { $0.agent == .codex })
            await model.clearAgents()
        }
    }
#endif
