import Testing

@testable import spacesui

@Suite struct PaneEmptyStateContentTests {
    @Test func emptyLibraryOffersToCreateAPromptWhenOneCanBeCreated() {
        let content = PaneEmptyStateContent.savedPrompts(query: "", canCreate: true)
        #expect(content.title == "No saved prompts")
        #expect(content.actionTitle == "Create a prompt")
    }

    @Test func emptyLibraryOffersNoActionWhenNoDeviceCanTakeAPrompt() {
        #expect(PaneEmptyStateContent.savedPrompts(query: "", canCreate: false).actionTitle == nil)
    }

    @Test func searchWithNoMatchNamesTheQueryProblemAndOffersNoAction() {
        let content = PaneEmptyStateContent.savedPrompts(query: "  deploy ", canCreate: true)
        #expect(content.title == "No matching prompts")
        #expect(content.actionTitle == nil)
    }

    @Test func aWhitespaceOnlyQueryCountsAsNoSearch() {
        #expect(PaneEmptyStateContent.savedPrompts(query: "   ", canCreate: true).title == "No saved prompts")
    }

    @Test func onlyTheNoAutomationsStateOffersAnAction() {
        #expect(PaneEmptyStateContent.noAutomations.actionTitle == "Create an automation")
        #expect(PaneEmptyStateContent.noRuns.actionTitle == nil)
        #expect(PaneEmptyStateContent.alertsAllClear.actionTitle == nil)
    }

    @Test func sessionsNameTheDeviceWhenItIsOfflineOrHasNoSessions() {
        #expect(PaneEmptyStateContent.sessionsOffline(deviceName: "Studio").title == "Studio is offline")
        #expect(PaneEmptyStateContent.sessionsEmpty(hasQuery: false, deviceName: "Studio").title == "No sessions on Studio")
    }

    @Test func sessionsSearchWithNoHitBlamesTheQueryNotTheDevice() {
        #expect(PaneEmptyStateContent.sessionsEmpty(hasQuery: true, deviceName: "Studio").title == "No sessions match")
        #expect(PaneEmptyStateContent.sessionsSearching.title == "Searching")
    }

    @Test func sessionsStatesOfferNoAction() {
        let states = [
            PaneEmptyStateContent.sessionsOffline(deviceName: "Studio"), .sessionsSearching,
            .sessionsEmpty(hasQuery: true, deviceName: "Studio"), .sessionsEmpty(hasQuery: false, deviceName: "Studio"),
        ]
        #expect(states.allSatisfy { $0.actionTitle == nil })
    }

    @Test func resourcesShowsLoadingUntilTheFirstMeasurementLands() {
        #expect(PaneEmptyStateContent.resources(hasMeasurement: false).title == "Measuring…")
        #expect(PaneEmptyStateContent.resources(hasMeasurement: true).title == "No terminals are running")
    }
}
