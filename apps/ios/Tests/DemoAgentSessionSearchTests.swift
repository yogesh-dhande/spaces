#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class DemoAgentSessionSearchTests: XCTestCase {
        private func backend(search: DemoAgentSessionSearch = DemoAgentSessionSearch()) throws -> DemoDeviceBackend {
            DemoDeviceBackend(library: try DemoRecordingLibrary.load(bundle: .main), agentSessionSearch: search)
        }

        private func search(_ backend: DemoDeviceBackend, query: String = "", page: Int = 0, agents: [CodingAgent]? = nil, projectID: String? = nil)
            async throws -> SpacesDeviceAgentSessionSearchResult
        {
            let response = await backend.serve(
                SpacesDeviceAPIRequest(command: .searchAgentSessions(.init(query: query, page: page, agents: agents, projectID: projectID))))
            XCTAssertTrue(response.ok, response.message)
            return try XCTUnwrap(response.agentSessionSearch)
        }

        func testBlankQueryListsTheSeedNewestFirstWithoutExcerpts() async throws {
            let listed = try await search(try backend())

            XCTAssertEqual(listed.results.count, DemoAgentSessionSearch.defaultSeeds.count)
            XCTAssertEqual(listed.results.map(\.lastActive), listed.results.map(\.lastActive).sorted(by: >))
            XCTAssertTrue(listed.results.allSatisfy { $0.excerpt == nil })
            XCTAssertFalse(listed.hasMore)
            XCTAssertFalse(listed.progress.isBuilding)
            XCTAssertFalse(listed.progress.isRefreshing)
        }

        func testSeedSpansSeveralAgentsAndTheFilterChoicesListThem() async throws {
            let listed = try await search(try backend())

            XCTAssertEqual(listed.availableAgents, CodingAgent.allCases)
        }

        func testQueryMatchesAllWordsInAnyOrderWithPrefixesAndShowsTheExcerpt() async throws {
            let found = try await search(try backend(), query: "REGRESSION expir")

            XCTAssertEqual(found.results.map(\.sessionKey), ["demo-session-checkout"])
            XCTAssertNotNil(found.results.first?.excerpt)
            let none = try await search(try backend(), query: "checkout pagination")
            XCTAssertTrue(none.results.isEmpty)
        }

        func testAgentFilterRestrictsResults() async throws {
            let codex = try await search(try backend(), agents: [.codex])

            XCTAssertFalse(codex.results.isEmpty)
            XCTAssertTrue(codex.results.allSatisfy { $0.agent == .codex })
        }

        func testProjectFilterListsTheDemoProjectsWithHomeLastAndRestrictsResults() async throws {
            let backend = try backend()
            let all = try await search(backend)

            let projects = all.availableProjects
            XCTAssertEqual(projects.last?.isHome, true, "Home comes last.")
            XCTAssertEqual(projects.filter(\.isHome).count, 1)
            XCTAssertTrue(projects.contains { $0.name == "harbor-web" })

            let harbor = try XCTUnwrap(projects.first { $0.name == "harbor-web" })
            let harborHits = try await search(backend, projectID: harbor.id)
            XCTAssertFalse(harborHits.results.isEmpty)
            XCTAssertTrue(harborHits.results.allSatisfy { $0.workspace.projectID == harbor.id })
            XCTAssertLessThan(harborHits.results.count, all.results.count)

            let home = try XCTUnwrap(projects.first(where: \.isHome))
            let homeHits = try await search(backend, projectID: home.id)
            XCTAssertTrue(homeHits.results.map(\.sessionKey).contains("demo-session-billing"))

            let unknown = try await search(backend, projectID: "no-such-project")
            XCTAssertTrue(unknown.results.isEmpty)
        }

        func testHitsMapToWorkspacesAndCarryTheirState() async throws {
            let listed = try await search(try backend())
            func hit(_ key: String) throws -> SpacesDeviceAgentSessionHit { try XCTUnwrap(listed.results.first { $0.sessionKey == key }) }

            XCTAssertEqual(try hit("demo-session-checkout").workspace.projectName, "harbor-web")
            XCTAssertEqual(try hit("demo-session-checkout").runningTerminalSessionID, "demo-harbor-agent")
            XCTAssertEqual(try hit("demo-session-build-cache").workspace.projectName, "harbor-web", "A folder inside a workspace maps to it.")
            XCTAssertEqual(try hit("demo-session-docs-search").pinnedName, "Docs search migration")
            XCTAssertEqual(try hit("demo-session-billing").workspace.projectName, "~", "A folder in no project maps to the home workspace.")
            XCTAssertEqual(try hit("demo-session-invoice-pdf").resumability, .folderMissing)
            XCTAssertEqual(try hit("demo-session-orders").resumability, .resumable)
        }

        func testPagingOverALargerSeedPagesTwentyAtATime() async throws {
            let seeds = (0..<25).map { index in
                DemoAgentSessionSeed(
                    agent: .codex, sessionKey: "paged-\(index)", title: "Paged session \(index)", workingDirectory: "/tmp",
                    ageSeconds: Double(index + 1), sizeBytes: 1, text: "paged", pinnedName: nil, runningTerminalSessionID: nil, folderIsMissing: false
                )
            }
            let backend = try backend(search: DemoAgentSessionSearch(seeds: seeds))

            let first = try await search(backend, page: 0)
            let second = try await search(backend, page: 1)

            XCTAssertEqual(first.results.count, 20)
            XCTAssertTrue(first.hasMore)
            XCTAssertEqual(second.results.map(\.sessionKey), (20..<25).map { "paged-\($0)" })
            XCTAssertFalse(second.hasMore)
        }

        func testResumingARunningSeedReturnsItsTerminalAndOthersAreUnsupported() async throws {
            let backend = try backend()

            let running = await backend.serve(
                SpacesDeviceAPIRequest(
                    command: .resumeAgentSession(.init(agent: .claudeCode, sessionKey: "demo-session-checkout", workingDirectory: nil))))
            XCTAssertTrue(running.ok, running.message)
            XCTAssertEqual(running.sessionID, "demo-harbor-agent")

            let other = await backend.serve(
                SpacesDeviceAPIRequest(
                    command: .resumeAgentSession(.init(agent: .claudeCode, sessionKey: "demo-session-orders", workingDirectory: nil))))
            XCTAssertFalse(other.ok)
            XCTAssertEqual(other.message, DemoDeviceBackend.unsupportedInDemo)
        }
    }
#endif
