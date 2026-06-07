import AppKit

@MainActor final class ProjectFieldRefs {
    let projectID: String
    let setupScriptSection: SetupScriptSection
    let stopScriptSection: StopScriptSection
    let portsSection: PortsSection
    let processesSection: ProcessesSection
    let browserSessionsSection: BrowserSessionsSection
    let agentLaunchersSection: AgentLaunchersSection
    let discardImportedConfigButton: NSButton
    var pendingImportUpdateAllWorkspaces = false

    init(
        projectID: String, setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        discardImportedConfigButton: NSButton
    ) {
        self.projectID = projectID
        self.setupScriptSection = setupScriptSection
        self.stopScriptSection = stopScriptSection
        self.portsSection = portsSection
        self.processesSection = processesSection
        self.browserSessionsSection = browserSessionsSection
        self.agentLaunchersSection = agentLaunchersSection
        self.discardImportedConfigButton = discardImportedConfigButton
    }
}
