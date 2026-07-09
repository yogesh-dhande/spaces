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
        let row = PortRowView(port: ServiceDefinition(name: "web"), portText: "3000:52341", displayURL: "http://web.demo.localhost:7391")

        #expect(row.collapsedPortTextForTesting == "3000:52341")
        #expect(row.collapsedDetailTextForTesting == "http://web.demo.localhost:7391")
    }

    @Test func collapsedPortRowHidesPortLabelWithoutPortText() {
        let row = PortRowView(port: ServiceDefinition(name: "web"))

        #expect(row.collapsedPortTextForTesting.isEmpty)
    }

    @Test func sectionUsesConfiguredPortDisplayValuesByIndex() {
        let section = PortsSection(
            ports: [ServiceDefinition(name: "api"), ServiceDefinition(name: "web")], collapsedDisplayPortTexts: ["3000", "3001:52341"],
            collapsedDisplayURLs: [nil, "http://web.demo.localhost:7391"])

        #expect(section.rowCount == 2)
        #expect(section.row(at: 0)?.collapsedPortTextForTesting == "3000")
        #expect(section.row(at: 1)?.collapsedPortTextForTesting == "3001:52341")
        #expect(section.row(at: 1)?.collapsedDetailTextForTesting == "http://web.demo.localhost:7391")
    }

    @Test func sectionShowsEnvironmentVariableHintsWhenEnabled() {
        let section = PortsSection(ports: [ServiceDefinition(name: "admin-ui")], showsEnvironmentVariableHints: true)

        #expect(section.row(at: 0)?.collapsedDetailTextForTesting == "SPACES_ADMIN_UI_PORT, SPACES_ADMIN_UI_URL")
    }

    @Test func sectionCommitsValidServiceNameOnBlur() {
        let section = PortsSection(showsEnvironmentVariableHints: true)
        var committedPorts: [ServiceDefinition] = []
        section.onCommit = { committedPorts = $0 }

        section.handleAdd(NSButton())
        section.row(at: 0)?.setEditingNameForTesting("web")
        section.row(at: 0)?.endEditingForTesting()

        #expect(!section.isEditing(at: 0))
        #expect(section.currentPorts.map(\.name) == ["web"])
        #expect(committedPorts.map(\.name) == ["web"])
        #expect(section.row(at: 0)?.collapsedDetailTextForTesting == "SPACES_WEB_PORT, SPACES_WEB_URL")
    }

    @Test func sectionNormalizesServiceNameCaseOnBlur() {
        let section = PortsSection(showsEnvironmentVariableHints: true)

        section.handleAdd(NSButton())
        section.row(at: 0)?.setEditingNameForTesting("PORT")
        section.row(at: 0)?.endEditingForTesting()

        #expect(!section.isEditing(at: 0))
        #expect(section.currentPorts.map(\.name) == ["port"])
        #expect(section.row(at: 0)?.collapsedDetailTextForTesting == "SPACES_PORT_PORT, SPACES_PORT_URL")
    }

    @Test func cancelDoesNotCommitValidDraftWhenEndingFieldEditingFirst() {
        let section = PortsSection(ports: [ServiceDefinition(name: "web")])
        var committedPorts: [ServiceDefinition] = []
        section.onCommit = { committedPorts = $0 }

        let row = section.row(at: 0)
        row?.onBeginEdit?()
        row?.setEditingNameForTesting("api")
        row?.suppressNextEditingEndedCommit()
        row?.endEditingForTesting()
        row?.onCancel?()

        #expect(!section.isEditing(at: 0))
        #expect(section.currentPorts.map(\.name) == ["web"])
        #expect(committedPorts.isEmpty)
    }

    @Test func sectionKeepsInvalidServiceNameEditingOnBlur() {
        let section = PortsSection()
        var committedPorts: [ServiceDefinition] = []
        section.onCommit = { committedPorts = $0 }

        section.handleAdd(NSButton())
        section.row(at: 0)?.setEditingNameForTesting("Bad Name")
        section.row(at: 0)?.endEditingForTesting()

        #expect(section.isEditing(at: 0))
        #expect(section.currentPorts.map(\.name) == [""])
        #expect(committedPorts.isEmpty)
    }

    @Test func reloadSwapsPortTextsWithoutDroppingOpenEditorDraft() {
        let section = PortsSection(ports: [ServiceDefinition(name: "web")], collapsedDisplayPortTexts: ["3000"])
        var committedPorts: [ServiceDefinition] = []
        section.onCommit = { committedPorts = $0 }
        section.row(at: 0)?.onBeginEdit?()
        section.row(at: 0)?.setEditingNameForTesting("api")
        #expect(section.isEditing(at: 0))

        section.reload(ports: section.currentPorts, collapsedDisplayPortTexts: ["3000:52341"])

        #expect(section.isEditing(at: 0))
        #expect(section.currentPorts.map(\.name) == ["web"])
        #expect(committedPorts.isEmpty)
        #expect(section.row(at: 0)?.collapsedPortTextForTesting == "3000:52341")
    }

    @Test func programmaticEditorTeardownDoesNotCommitValidDraft() {
        let section = PortsSection(ports: [ServiceDefinition(name: "web")])
        var committedPorts: [ServiceDefinition] = []
        section.onCommit = { committedPorts = $0 }

        let row = section.row(at: 0)
        row?.onBeginEdit?()
        row?.setEditingNameForTesting("api")
        row?.suppressNextEditingEndedCommit()
        row?.endEditingForTesting()

        #expect(section.isEditing(at: 0))
        #expect(section.currentPorts.map(\.name) == ["web"])
        #expect(committedPorts.isEmpty)
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
