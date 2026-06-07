import AppKit

@MainActor final class ProjectFieldRefs {
    let projectID: String
    let setupScriptSection: SetupScriptSection
    let stopScriptSection: StopScriptSection
    let portsSection: PortsSection
    let processesSection: ProcessesSection
    let browserSessionsSection: BrowserSessionsSection
    let agentLaunchersSection: AgentLaunchersSection
    let importButton: NSButton
    let exportButton: NSButton
    let discardImportedConfigButton: NSButton
    var pendingImportUpdateAllWorkspaces = false

    init(
        projectID: String, setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        importButton: NSButton, exportButton: NSButton, discardImportedConfigButton: NSButton
    ) {
        self.projectID = projectID
        self.setupScriptSection = setupScriptSection
        self.stopScriptSection = stopScriptSection
        self.portsSection = portsSection
        self.processesSection = processesSection
        self.browserSessionsSection = browserSessionsSection
        self.agentLaunchersSection = agentLaunchersSection
        self.importButton = importButton
        self.exportButton = exportButton
        self.discardImportedConfigButton = discardImportedConfigButton
    }
}
