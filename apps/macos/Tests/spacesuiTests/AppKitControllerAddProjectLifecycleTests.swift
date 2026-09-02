import AppKit
import Foundation
import Testing

@testable import spacesui

@Suite struct AppKitControllerAddProjectLifecycleTests {
    @Test func addProjectRequiresDeviceSelectionOnlyWithMultipleDevices() {
        // A single device (the local Mac) skips the device step and opens configuration directly.
        #expect(!ProjectFormsController.addProjectRequiresDeviceSelection(deviceCount: 1))
        // More than one paired device shows the device-selection step first.
        #expect(ProjectFormsController.addProjectRequiresDeviceSelection(deviceCount: 2))
    }

    @MainActor @Test func setupScriptReplaceCancelsOpenEditorAndAppliesHydratedValue() {
        let section = ScriptSection(
            title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script", value: "old")
        section.editButtonForLifecycleTests?.performClick(nil)
        #expect(section.isEditing)

        section.reload(value: "ignored")
        #expect(section.currentValue == "old")

        section.replace(value: "hydrated")
        #expect(!section.isEditing)
        #expect(section.currentValue == "hydrated")
    }

    @MainActor @Test func stopScriptReplaceCancelsOpenEditorAndAppliesHydratedValue() {
        let section = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script", value: "old")
        section.editButtonForLifecycleTests?.performClick(nil)
        #expect(section.isEditing)

        section.reload(value: "ignored")
        #expect(section.currentValue == "old")

        section.replace(value: "hydrated")
        #expect(!section.isEditing)
        #expect(section.currentValue == "hydrated")
    }

    @MainActor @Test func projectExportPendingStateIncludesOpenSectionEditors() {
        let refs = makeProjectFieldRefs()
        #expect(!refs.hasOpenSectionEditor)

        refs.setupScriptSection.editButtonForLifecycleTests?.performClick(nil)
        #expect(refs.hasOpenSectionEditor)

        refs.setupScriptSection.replace(value: "saved")
        #expect(!refs.hasOpenSectionEditor)

        refs.portsSection.handleAdd(NSButton())
        #expect(refs.hasOpenSectionEditor)
    }

    @MainActor @Test func importedProjectSaveDecisionMapsAlertResponses() {
        #expect(ProjectFormsController.projectImportWorkspaceSyncDecision(for: .alertFirstButtonReturn) == .updateAllWorkspaces)
        #expect(ProjectFormsController.projectImportWorkspaceSyncDecision(for: .alertSecondButtonReturn) == .projectOnly)
        #expect(ProjectFormsController.projectImportWorkspaceSyncDecision(for: .alertThirdButtonReturn) == .cancel)
        #expect(ProjectFormsController.projectImportWorkspaceSyncDecision(for: .abort) == .cancel)
    }

    @MainActor @Test func nonGitProjectSaveAlwaysSyncsItsWorkspace() {
        // A non-git project stands in for its single workspace, so saving its settings must sync to
        // that workspace regardless of any pending-import choice — the edits are the config that runs.
        #expect(ProjectFormsController.projectSaveSyncsAllWorkspaces(isGitRepo: false, pendingImportUpdateAllWorkspaces: false))
        #expect(ProjectFormsController.projectSaveSyncsAllWorkspaces(isGitRepo: false, pendingImportUpdateAllWorkspaces: true))
    }

    @MainActor @Test func gitProjectSaveSyncsOnlyWhenImportChoseUpdateAll() {
        // A git project keeps the template/per-workspace split: a plain save leaves existing
        // workspaces untouched, and only a pending import that chose Update All Workspaces syncs.
        #expect(!ProjectFormsController.projectSaveSyncsAllWorkspaces(isGitRepo: true, pendingImportUpdateAllWorkspaces: false))
        #expect(ProjectFormsController.projectSaveSyncsAllWorkspaces(isGitRepo: true, pendingImportUpdateAllWorkspaces: true))
    }

    @MainActor @Test func managedDirectoryReplacementDecisionMapsAlertResponses() {
        #expect(ProjectFormsController.managedDirectoryReplacementDecision(for: .alertFirstButtonReturn) == .replace)
        #expect(ProjectFormsController.managedDirectoryReplacementDecision(for: .alertSecondButtonReturn) == .cancel)
        #expect(ProjectFormsController.managedDirectoryReplacementDecision(for: .abort) == .cancel)
    }

    @MainActor @Test func managedDirectoryReplacementCancelStopsFlow() {
        #expect(ProjectFormsController.shouldStartManagedDirectoryReplacementFlow(candidateCount: 0, decision: .cancel))
        #expect(ProjectFormsController.shouldStartManagedDirectoryReplacementFlow(candidateCount: 1, decision: .replace))
        #expect(!ProjectFormsController.shouldStartManagedDirectoryReplacementFlow(candidateCount: 1, decision: .cancel))
    }

    @MainActor @Test func importedProjectSaveDecisionUpdatesWorkspaceSyncFlag() {
        let refs = makeProjectFieldRefs()

        #expect(ProjectFormsController.applyProjectImportWorkspaceSyncDecision(.updateAllWorkspaces, to: refs))
        #expect(refs.pendingImportUpdateAllWorkspaces)

        #expect(ProjectFormsController.applyProjectImportWorkspaceSyncDecision(.projectOnly, to: refs))
        #expect(!refs.pendingImportUpdateAllWorkspaces)

        refs.pendingImportUpdateAllWorkspaces = true
        #expect(!ProjectFormsController.applyProjectImportWorkspaceSyncDecision(.cancel, to: refs))
        #expect(refs.pendingImportUpdateAllWorkspaces)
    }

    @MainActor @Test func liveFormRefsHonorsTheSenderMatchingTheLiveForm() {
        // A control from the live form carries the form's generation tag, so its action resolves to
        // the live refs and is honored.
        let refs = makeProjectFieldRefs(formTag: 7)
        #expect(ProjectFormsController.liveFormRefs(refs, forSenderTag: 7) === refs)
    }

    @MainActor @Test func liveFormRefsIgnoresSenderFromAReplacedForm() {
        // Rebuilding a single-instance dialog replaces its refs with a new generation. A queued action
        // from the previous form still carries the old tag, so it must resolve to nil (be dropped)
        // rather than mutate the current form's state.
        let liveRefs = makeProjectFieldRefs(formTag: 2)
        let staleSenderTag = 1
        #expect(ProjectFormsController.liveFormRefs(liveRefs, forSenderTag: staleSenderTag) == nil)
    }

    @MainActor @Test func liveFormRefsIgnoresSenderWhenNoFormIsLive() {
        // After the dialog closes its refs are nil, so any late action is dropped instead of crashing.
        #expect(ProjectFormsController.liveFormRefs(nil as ProjectFieldRefs?, forSenderTag: 3) == nil)
    }

    @MainActor private func makeProjectFieldRefs(formTag: Int = "project".hashValue) -> ProjectFieldRefs {
        ProjectFieldRefs(
            formTag: formTag, projectID: "project",
            setupScriptSection: ScriptSection(
                title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script", value: ""),
            stopScriptSection: ScriptSection(
                title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script", value: ""),
            portsSection: PortsSection(), processesSection: ProcessesSection(showsRuntimeControls: false),
            browserSessionsSection: BrowserSessionsSection(), importButton: NSButton(), exportButton: NSButton(),
            discardImportedConfigButton: NSButton())
    }
}

extension ScriptSection {
    fileprivate var editButtonForLifecycleTests: NSButton? {
        view.addProjectLifecycleSubviewsRecursive().compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier().hasSuffix("-script-edit") }
    }
}

extension NSView {
    fileprivate func addProjectLifecycleSubviewsRecursive() -> [NSView] { subviews + subviews.flatMap { $0.addProjectLifecycleSubviewsRecursive() } }
}
