import AppKit
import workspacecore

@MainActor final class AddProjectFieldRefs {
    let sourceSegmented: NSSegmentedControl
    let localSourceSection: NSStackView
    let cloneSourceSection: NSStackView
    let dirField: NSTextField
    let repoURLField: NSTextField
    let prepareButton: NSButton
    let progressiveInputViews: [NSView]
    let createButton: NSButton
    let setupScriptSection: SetupScriptSection
    let stopScriptSection: StopScriptSection
    let portsSection: PortsSection
    let processesSection: ProcessesSection
    let browserSessionsSection: BrowserSessionsSection
    let agentLaunchersSection: AgentLaunchersSection
    var preparedLocalDirectoryPath: String?
    var preparedGitURL: String?
    var preparedGitProject: WorkspaceOrchestrator.PreparedGitProjectImport?
    var gitPreparationID: UUID?
    var directorySuggestionTask: Task<Void, Never>?
    var directoryPreviewTask: Task<Void, Never>?
    var directoryCompletions: [String] = []
    /// The device the project will be created on. Defaults to the local Mac; the
    /// New Project form lets the user pick another paired device.
    var selectedDeviceID: String = SpacesDeviceRecord.localDeviceID

    init(
        sourceSegmented: NSSegmentedControl, localSourceSection: NSStackView, cloneSourceSection: NSStackView, dirField: NSTextField,
        repoURLField: NSTextField, prepareButton: NSButton, progressiveInputViews: [NSView], createButton: NSButton,
        setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection, processesSection: ProcessesSection,
        browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection
    ) {
        self.sourceSegmented = sourceSegmented
        self.localSourceSection = localSourceSection
        self.cloneSourceSection = cloneSourceSection
        self.dirField = dirField
        self.repoURLField = repoURLField
        self.prepareButton = prepareButton
        self.progressiveInputViews = progressiveInputViews
        self.createButton = createButton
        self.setupScriptSection = setupScriptSection
        self.stopScriptSection = stopScriptSection
        self.portsSection = portsSection
        self.processesSection = processesSection
        self.browserSessionsSection = browserSessionsSection
        self.agentLaunchersSection = agentLaunchersSection
    }
}
