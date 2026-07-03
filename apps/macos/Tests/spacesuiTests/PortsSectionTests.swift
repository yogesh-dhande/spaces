import AppKit
import Testing
import workspacecore

@testable import spacesui

@MainActor @Suite struct PortsSectionTests {
    @Test func collapsedPortRowShowsReservedPortValue() {
        let row = PortRowView(port: ServiceDefinition(name: "api"), reservedPort: 3000)

        #expect(row.collapsedPrimaryTextForTesting == "api")
        #expect(row.collapsedPrimaryTextIsSelectableForTesting)
        #expect(row.collapsedDetailTextForTesting == "3000")
    }

    @Test func sectionUsesConfiguredPortDisplayValuesByIndex() {
        let section = PortsSection(ports: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")], collapsedDisplayPorts: [3000, 3001])

        #expect(section.rowCount == 2)
        #expect(section.row(at: 0)?.collapsedDetailTextForTesting == "3000")
        #expect(section.row(at: 1)?.collapsedDetailTextForTesting == "3001")
    }

    @Test func collapsedServiceRowPrefersServiceURLOverPort() {
        let row = PortRowView(port: ServiceDefinition(name: "web"), reservedPort: 21001, displayURL: "http://web.demo.localhost:7391")

        #expect(row.collapsedPrimaryTextForTesting == "web")
        #expect(row.collapsedDetailTextForTesting == "http://web.demo.localhost:7391")
    }

    @Test func sectionPassesServiceURLsByIndex() {
        let section = PortsSection(
            ports: [ServiceDefinition(name: "web"), ServiceDefinition(name: "backend")], collapsedDisplayPorts: [21001, 21002],
            collapsedDisplayURLs: ["http://web.demo.localhost:7391", nil])

        #expect(section.row(at: 0)?.collapsedDetailTextForTesting == "http://web.demo.localhost:7391")
        // Falls back to the bare port when no URL is provided for that index.
        #expect(section.row(at: 1)?.collapsedDetailTextForTesting == "21002")
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
