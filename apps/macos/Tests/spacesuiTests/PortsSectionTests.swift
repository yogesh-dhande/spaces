import AppKit
import Testing
import workspacecore

@testable import spacesui

@MainActor @Suite struct PortsSectionTests {
    @Test func collapsedPortRowShowsPortTextInMonospace() {
        let row = PortRowView(port: ServiceDefinition(name: "api"), portText: "3000")

        #expect(row.collapsedPrimaryTextForTesting == "api")
        #expect(row.collapsedPrimaryTextIsSelectableForTesting)
        #expect(row.collapsedPortTextForTesting == "3000")
        #expect(row.collapsedDetailTextForTesting.isEmpty)
    }

    @Test func collapsedPortRowShowsRemoteLocalPortPairNextToServiceURL() {
        let row = PortRowView(port: ServiceDefinition(name: "web"), portText: "3000:52341", displayURL: "http://web.demo.localhost:8088")

        #expect(row.collapsedPortTextForTesting == "3000:52341")
        #expect(row.collapsedDetailTextForTesting == "http://web.demo.localhost:8088")
    }

    @Test func collapsedPortRowHidesPortLabelWithoutPortText() {
        let row = PortRowView(port: ServiceDefinition(name: "web"))

        #expect(row.collapsedPortTextForTesting.isEmpty)
    }

    @Test func sectionUsesConfiguredPortDisplayValuesByIndex() {
        let section = PortsSection(
            ports: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")], collapsedDisplayPortTexts: ["3000", "3001:52341"],
            collapsedDisplayURLs: [nil, "http://web.demo.localhost:8088"])

        #expect(section.rowCount == 2)
        #expect(section.row(at: 0)?.collapsedPortTextForTesting == "3000")
        #expect(section.row(at: 1)?.collapsedPortTextForTesting == "3001:52341")
        #expect(section.row(at: 1)?.collapsedDetailTextForTesting == "http://web.demo.localhost:8088")
    }

    @Test func reloadSwapsPortTextsWithoutDroppingOpenEditorDraft() {
        let section = PortsSection(ports: [ServiceDefinition(name: "web")], collapsedDisplayPortTexts: ["3000"])
        section.row(at: 0)?.onBeginEdit?()
        #expect(section.isEditing(at: 0))

        section.reload(ports: section.currentPorts, collapsedDisplayPortTexts: ["3000:52341"])

        #expect(section.isEditing(at: 0))
        #expect(section.row(at: 0)?.collapsedPortTextForTesting == "3000:52341")
    }

    @Test func replaceClearsDraftStateBeforeLoadingImportedPorts() {
        let section = PortsSection(ports: [ServiceDefinition(name: "web")])
        section.handleAdd(NSButton())
        #expect(section.isEditing(at: 1))

        section.replace(ports: [ServiceDefinition(name: "imported")])

        var presentedFor: ServiceDefinition?
        section.presentRemoveConfirmation = { port, decide in
            presentedFor = port
            decide(false)
        }
        section.row(at: 0)?.onRemove?()

        #expect(section.rowCount == 1)
        #expect(section.currentPorts.map(\.name) == ["imported"])
        #expect(presentedFor?.name == "imported")
        #expect(!section.isEditing(at: 0))
    }
}
