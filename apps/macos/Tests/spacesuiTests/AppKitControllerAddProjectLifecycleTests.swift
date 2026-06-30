import AppKit
import Foundation
import Testing

@testable import spacesui

@Suite struct AppKitControllerAddProjectLifecycleTests {
    @Test func preparedGitProjectResultRequiresActiveMatchingRequest() {
        let preparationID = UUID()

        #expect(
            AppKitController.preparedGitProjectResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 1, currentRepoURL: "https://example.com/repo.git",
                requestedRepoURL: "https://example.com/repo.git", currentPreparationID: preparationID, completionPreparationID: preparationID))
    }

    @Test func preparedGitProjectResultRejectsStaleOrInactiveRequests() {
        let preparationID = UUID()

        #expect(
            !AppKitController.preparedGitProjectResultMatchesActiveRequest(
                isActiveForm: false, selectedSegment: 1, currentRepoURL: "https://example.com/repo.git",
                requestedRepoURL: "https://example.com/repo.git", currentPreparationID: preparationID, completionPreparationID: preparationID))
        #expect(
            !AppKitController.preparedGitProjectResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 0, currentRepoURL: "https://example.com/repo.git",
                requestedRepoURL: "https://example.com/repo.git", currentPreparationID: preparationID, completionPreparationID: preparationID))
        #expect(
            !AppKitController.preparedGitProjectResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 1, currentRepoURL: "https://example.com/other.git",
                requestedRepoURL: "https://example.com/repo.git", currentPreparationID: preparationID, completionPreparationID: preparationID))
        #expect(
            !AppKitController.preparedGitProjectResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 1, currentRepoURL: "https://example.com/repo.git",
                requestedRepoURL: "https://example.com/repo.git", currentPreparationID: UUID(), completionPreparationID: preparationID))
    }

    @Test func localProjectPreviewResultRequiresActiveLocalSource() {
        #expect(
            AppKitController.localProjectPreviewResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 0, currentDirectoryPath: "/tmp/project", requestedDirectoryPath: "/tmp/project"))
    }

    @Test func localProjectPreviewResultRejectsStaleOrInactiveRequests() {
        #expect(
            !AppKitController.localProjectPreviewResultMatchesActiveRequest(
                isActiveForm: false, selectedSegment: 0, currentDirectoryPath: "/tmp/project", requestedDirectoryPath: "/tmp/project"))
        #expect(
            !AppKitController.localProjectPreviewResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 1, currentDirectoryPath: "/tmp/project", requestedDirectoryPath: "/tmp/project"))
        #expect(
            !AppKitController.localProjectPreviewResultMatchesActiveRequest(
                isActiveForm: true, selectedSegment: 0, currentDirectoryPath: "/tmp/other", requestedDirectoryPath: "/tmp/project"))
    }

    @Test func preparedGitProjectDiscardKeyUsesTrimmedRepoURL() {
        #expect(AppKitController.preparedGitProjectDiscardKey(repoURL: "  https://example.com/repo.git\n") == "https://example.com/repo.git")
        #expect(AppKitController.preparedGitProjectDiscardKey(repoURL: "   ") == nil)
        #expect(AppKitController.preparedGitProjectDiscardKey(repoURL: nil) == nil)
    }

    @Test func preparedGitProjectCreateFailureRestoresHandleToStillActiveForm() {
        #expect(
            AppKitController.preparedGitProjectCreateFailureAction(
                isActiveForm: true, formHasPreparedHandle: false, formTargetsPreparationDevice: true) == .restoreToForm)
    }

    @Test func preparedGitProjectCreateFailureDiscardsOrphanedClone() {
        // Form dismissed mid-create, so there is nothing to restore into.
        #expect(
            AppKitController.preparedGitProjectCreateFailureAction(
                isActiveForm: false, formHasPreparedHandle: false, formTargetsPreparationDevice: true) == .discardOrphan)
        // A newer preparation already replaced the handle on the still-active form; the captured
        // clone is orphaned and discarding it must not clobber the newer one.
        #expect(
            AppKitController.preparedGitProjectCreateFailureAction(
                isActiveForm: true, formHasPreparedHandle: true, formTargetsPreparationDevice: true) == .discardOrphan)
        #expect(
            AppKitController.preparedGitProjectCreateFailureAction(
                isActiveForm: false, formHasPreparedHandle: true, formTargetsPreparationDevice: true) == .discardOrphan)
    }

    @Test func preparedGitProjectCreateFailureDiscardsWhenFormSwitchedDevices() {
        // The user changed the (still-editable) device picker mid-create, so the form now targets a
        // different daemon than the one the clone was prepared on. Restoring the handle would make
        // Cancel/retry act on the wrong daemon and orphan the original clone, so discard it on its own
        // device instead.
        #expect(
            AppKitController.preparedGitProjectCreateFailureAction(
                isActiveForm: true, formHasPreparedHandle: false, formTargetsPreparationDevice: false) == .discardOrphan)
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
        #expect(AppKitController.projectImportWorkspaceSyncDecision(for: .alertFirstButtonReturn) == .updateAllWorkspaces)
        #expect(AppKitController.projectImportWorkspaceSyncDecision(for: .alertSecondButtonReturn) == .projectOnly)
        #expect(AppKitController.projectImportWorkspaceSyncDecision(for: .alertThirdButtonReturn) == .cancel)
        #expect(AppKitController.projectImportWorkspaceSyncDecision(for: .abort) == .cancel)
    }

    @MainActor @Test func managedDirectoryReplacementDecisionMapsAlertResponses() {
        #expect(AppKitController.managedDirectoryReplacementDecision(for: .alertFirstButtonReturn) == .replace)
        #expect(AppKitController.managedDirectoryReplacementDecision(for: .alertSecondButtonReturn) == .cancel)
        #expect(AppKitController.managedDirectoryReplacementDecision(for: .abort) == .cancel)
    }

    @MainActor @Test func managedDirectoryReplacementCancelStopsFlow() {
        #expect(AppKitController.shouldStartManagedDirectoryReplacementFlow(candidateCount: 0, decision: .cancel))
        #expect(AppKitController.shouldStartManagedDirectoryReplacementFlow(candidateCount: 1, decision: .replace))
        #expect(!AppKitController.shouldStartManagedDirectoryReplacementFlow(candidateCount: 1, decision: .cancel))
    }

    @MainActor @Test func importedProjectSaveDecisionUpdatesWorkspaceSyncFlag() {
        let refs = makeProjectFieldRefs()

        #expect(AppKitController.applyProjectImportWorkspaceSyncDecision(.updateAllWorkspaces, to: refs))
        #expect(refs.pendingImportUpdateAllWorkspaces)

        #expect(AppKitController.applyProjectImportWorkspaceSyncDecision(.projectOnly, to: refs))
        #expect(!refs.pendingImportUpdateAllWorkspaces)

        refs.pendingImportUpdateAllWorkspaces = true
        #expect(!AppKitController.applyProjectImportWorkspaceSyncDecision(.cancel, to: refs))
        #expect(refs.pendingImportUpdateAllWorkspaces)
    }

    @MainActor private func makeProjectFieldRefs() -> ProjectFieldRefs {
        ProjectFieldRefs(
            projectID: "project",
            setupScriptSection: ScriptSection(
                title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script", value: ""),
            stopScriptSection: ScriptSection(
                title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script", value: ""),
            portsSection: PortsSection(), processesSection: ProcessesSection(showsRuntimeControls: false),
            browserSessionsSection: BrowserSessionsSection(), agentLaunchersSection: AgentLaunchersSection(), importButton: NSButton(),
            exportButton: NSButton(), discardImportedConfigButton: NSButton())
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
