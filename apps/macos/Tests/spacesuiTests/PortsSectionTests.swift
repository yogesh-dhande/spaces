import AppKit
import Testing
import workspacecore

@testable import spacesui

@MainActor @Suite struct PortsSectionTests {
    @Test func collapsedPortRowShowsReservedPortValue() {
        let row = PortRowView(port: PortDefinition(name: "API_PORT"), reservedPort: 3000)

        #expect(row.collapsedPrimaryTextForTesting == "API_PORT")
        #expect(row.collapsedDetailTextForTesting == "3000")
    }

    @Test func sectionUsesConfiguredPortDisplayValuesByIndex() {
        let section = PortsSection(ports: [PortDefinition(name: "API_PORT"), PortDefinition(name: "WEB_PORT")], collapsedDisplayPorts: [3000, 3001])

        #expect(section.rowCount == 2)
        #expect(section.row(at: 0)?.collapsedDetailTextForTesting == "3000")
        #expect(section.row(at: 1)?.collapsedDetailTextForTesting == "3001")
    }
}
