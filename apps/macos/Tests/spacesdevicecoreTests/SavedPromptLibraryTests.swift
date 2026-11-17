// `SavedPromptLibrary` is compiled out on Linux (it is client-only), so this test is too.
#if !os(Linux)

    import Foundation
    import Testing
    import spacesterminalcore

    @testable import spacesdevicecore

    /// The merged prompt list both clients show: how devices' prompts order and search together, and when
    /// a device's list is fetched again.
    @Suite struct SavedPromptLibraryTests {
        private func prompt(
            _ id: String, title: String? = nil, text: String = "body", created: String = "2026-11-13T10:00:00.000Z", used: String? = nil
        ) -> SpacesDeviceSavedPrompt {
            SpacesDeviceSavedPrompt(id: id, title: title ?? id, text: text, createdAt: created, updatedAt: created, lastUsedAt: used ?? created)
        }

        private func device(_ id: String, revision: Int = 1) -> SavedPromptLibrary.Device {
            SavedPromptLibrary.Device(id: id, name: "Device \(id)", overviewRevision: revision)
        }

        private func result(_ prompts: [SpacesDeviceSavedPrompt], revision: Int = 1) -> SpacesDeviceSavedPromptsResult {
            SpacesDeviceSavedPromptsResult(prompts: prompts, revision: revision)
        }

        /// A library holding `a` and `b`, each with the prompts given, both fetched at revision 1.
        private func library(a: [SpacesDeviceSavedPrompt], b: [SpacesDeviceSavedPrompt] = []) -> SavedPromptLibrary {
            var library = SavedPromptLibrary()
            _ = library.reconcile(reachable: [device("a"), device("b")])
            library.apply(result(a), deviceID: "a")
            library.apply(result(b), deviceID: "b")
            return library
        }

        @Test func mergesDevicesMostRecentlyUsedFirst() {
            let library = library(
                a: [prompt("a-old", used: "2026-11-13T10:00:00.000Z"), prompt("a-new", used: "2026-11-13T12:00:00.000Z")],
                b: [prompt("b-mid", used: "2026-11-13T11:00:00.000Z")])
            #expect(library.entries(matching: "").map(\.prompt.id) == ["a-new", "b-mid", "a-old"])
            #expect(library.count == 3)
        }

        @Test func tiesBreakByCreationThenDevicePositionThenID() {
            let used = "2026-11-13T12:00:00.000Z"
            let library = library(
                a: [
                    prompt("a-2", created: "2026-11-13T09:00:00.000Z", used: used), prompt("a-1", created: "2026-11-13T09:00:00.000Z", used: used),
                    prompt("a-newer", created: "2026-11-13T09:30:00.000Z", used: used),
                ], b: [prompt("b-1", created: "2026-11-13T09:00:00.000Z", used: used)])
            #expect(library.entries(matching: "").map(\.id) == ["a/a-newer", "a/a-1", "a/a-2", "b/b-1"])
        }

        @Test func entriesCarryTheOwningDevice() throws {
            let library = library(a: [prompt("p")], b: [prompt("q")])
            let entry = try #require(library.entries(matching: "").first { $0.prompt.id == "q" })
            #expect(entry.deviceID == "b")
            #expect(entry.deviceName == "Device b")
        }

        @Test func searchIgnoresCaseAndDiacriticsAndLooksInTitleAndText() {
            let library = library(a: [
                prompt("one", title: "Résumé review", text: "x"), prompt("two", title: "plain", text: "Check the DIFF carefully"),
            ])
            #expect(library.entries(matching: "resume").map(\.prompt.id) == ["one"])
            #expect(library.entries(matching: "diff").map(\.prompt.id) == ["two"])
            #expect(library.entries(matching: "  DIFF ").map(\.prompt.id) == ["two"])
            #expect(library.entries(matching: "absent").isEmpty)
        }

        @Test func anUnreachableDeviceIsHiddenThenFetchedAgainWhenItReturns() {
            var library = library(a: [prompt("a1")], b: [prompt("b1")])
            #expect(library.reconcile(reachable: [device("a")]).isEmpty)
            #expect(library.entries(matching: "").map(\.prompt.id) == ["a1"])
            #expect(library.reconcile(reachable: [device("a"), device("b")]) == ["b"])
        }

        @Test func aDeviceIsFetchedWhenItHasNoSliceOrANewerRevision() {
            var library = SavedPromptLibrary()
            #expect(library.reconcile(reachable: [device("a", revision: 3), device("b", revision: 0)]) == ["a", "b"])
            library.apply(result([], revision: 3), deviceID: "a")
            library.apply(result([], revision: 0), deviceID: "b")
            #expect(library.reconcile(reachable: [device("a", revision: 3), device("b", revision: 0)]).isEmpty)
            #expect(library.reconcile(reachable: [device("a", revision: 4), device("b", revision: 0)]) == ["a"])
        }

        @Test func aFetchInFlightIsNotStartedTwiceAndAFailureIsRetried() {
            var library = SavedPromptLibrary()
            #expect(library.reconcile(reachable: [device("a")]) == ["a"])
            #expect(library.reconcile(reachable: [device("a")]).isEmpty)
            library.fetchFailed(deviceID: "a")
            #expect(library.reconcile(reachable: [device("a")]) == ["a"])
        }

        @Test func aDeviceThatLeftWhileFetchingIsFetchedAgainOnReturn() {
            var library = SavedPromptLibrary()
            #expect(library.reconcile(reachable: [device("a")]) == ["a"])
            #expect(library.reconcile(reachable: []).isEmpty)
            #expect(library.reconcile(reachable: [device("a")]) == ["a"])
        }

        @Test func anOlderResultIsIgnoredAndANewerOneReplacesTheSlice() {
            var library = SavedPromptLibrary()
            _ = library.reconcile(reachable: [device("a", revision: 5)])
            library.apply(result([prompt("fresh")], revision: 5), deviceID: "a")
            library.apply(result([prompt("stale")], revision: 4), deviceID: "a")
            #expect(library.entries(matching: "").map(\.prompt.id) == ["fresh"])
            library.apply(result([prompt("newest")], revision: 6), deviceID: "a")
            #expect(library.entries(matching: "").map(\.prompt.id) == ["newest"])
        }

        @Test func aResultForADeviceNotReachableIsDropped() {
            var library = SavedPromptLibrary()
            _ = library.reconcile(reachable: [device("a")])
            library.apply(result([prompt("ghost")]), deviceID: "gone")
            #expect(library.count == 0)
        }

        @Test func aMutationResponseOutrunsTheOverviewRevisionWithoutAnotherFetch() {
            var library = SavedPromptLibrary()
            _ = library.reconcile(reachable: [device("a", revision: 1)])
            library.apply(result([prompt("p")], revision: 1), deviceID: "a")
            library.apply(result([prompt("p"), prompt("q")], revision: 2), deviceID: "a")
            #expect(library.reconcile(reachable: [device("a", revision: 2)]).isEmpty)
            #expect(library.count == 2)
        }

        @Test func anOverviewWithoutTheRevisionDoesNotDecode() throws {
            let overview = SpacesDeviceOverviewPayload(
                workspaces: [], sessions: [],
                daemonStatus: TerminalServiceDaemonStatus(version: "t", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0),
                savedPromptsRevision: 7)
            let encoded = try JSONEncoder().encode(overview)
            #expect(try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: encoded).savedPromptsRevision == 7)
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "savedPromptsRevision")
            let stripped = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: stripped) }
        }

        /// An absent list must not read as "no teardown in flight": that is the wrong answer for the one
        /// field that tells a client a still-listed workspace is being deleted rather than gone or failed.
        @Test func anOverviewWithoutTheTeardownInFlightListDoesNotDecode() throws {
            let overview = SpacesDeviceOverviewPayload(
                workspaces: [], sessions: [], workspaceIDsWithTeardownInFlight: ["ws-1"],
                daemonStatus: TerminalServiceDaemonStatus(version: "t", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0))
            let encoded = try JSONEncoder().encode(overview)
            #expect(try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: encoded).workspaceIDsWithTeardownInFlight == ["ws-1"])
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "workspaceIDsWithTeardownInFlight")
            let stripped = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(SpacesDeviceOverviewPayload.self, from: stripped) }
        }
    }

#endif
