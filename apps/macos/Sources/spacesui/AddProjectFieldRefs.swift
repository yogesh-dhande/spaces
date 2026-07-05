import AppKit
import workspacecore

/// The kind of source a new project is created from, chosen on the source step.
enum AddProjectSourceKind {
    case folder
    case git
}

@MainActor final class AddProjectFieldRefs {
    // MARK: Source step
    /// The two clickable source rows; the selected one is highlighted and reveals its input.
    let folderRow: ClickableRowView
    let gitRow: ClickableRowView
    /// Containers holding the folder-path and git-URL inputs, shown per selected source.
    let folderInputRow: NSView
    let gitInputRow: NSView
    let dirField: NSTextField
    let repoURLField: NSTextField
    let continueButton: NSButton
    /// The chosen source kind, or `nil` until the user picks a row.
    var selectedSourceKind: AddProjectSourceKind?

    // MARK: Config step
    let setupScriptSection: ScriptSection
    let stopScriptSection: ScriptSection
    let portsSection: PortsSection
    let processesSection: ProcessesSection
    let browserSessionsSection: BrowserSessionsSection
    let agentLaunchersSection: AgentLaunchersSection
    let createButton: NSButton
    /// Gentle note shown on the config step when a git repo has no `spaces.yaml`.
    let spacesYAMLMissingLabel: NSTextField
    /// Whether the loaded git source had no `spaces.yaml`, driving the note above.
    var spacesYAMLMissing = false

    // MARK: Shared
    /// The device the project will be created on, chosen in the device step (or the local Mac when it
    /// is the only device). Fixed for the lifetime of this flow.
    var selectedDeviceID: String = SpacesDeviceRecord.localDeviceID
    var directorySuggestionTask: Task<Void, Never>?
    var directoryCompletions: [String] = []

    init(
        folderRow: ClickableRowView, gitRow: ClickableRowView, folderInputRow: NSView, gitInputRow: NSView, dirField: NSTextField,
        repoURLField: NSTextField, continueButton: NSButton, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection,
        portsSection: PortsSection, processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection,
        agentLaunchersSection: AgentLaunchersSection, createButton: NSButton, spacesYAMLMissingLabel: NSTextField
    ) {
        self.folderRow = folderRow
        self.gitRow = gitRow
        self.folderInputRow = folderInputRow
        self.gitInputRow = gitInputRow
        self.dirField = dirField
        self.repoURLField = repoURLField
        self.continueButton = continueButton
        self.setupScriptSection = setupScriptSection
        self.stopScriptSection = stopScriptSection
        self.portsSection = portsSection
        self.processesSection = processesSection
        self.browserSessionsSection = browserSessionsSection
        self.agentLaunchersSection = agentLaunchersSection
        self.createButton = createButton
        self.spacesYAMLMissingLabel = spacesYAMLMissingLabel
    }
}
