import AppKit
import Testing

@testable import spacesui

@MainActor @Suite struct AppKitControllerAddWorkspaceBranchTests {
    @Test func existingWorkspaceBranchValuePrefersSelectedComboBoxItemOverStaleText() {
        let comboBox = NSComboBox()
        comboBox.addItems(withObjectValues: ["feature/a", "feature/b"])
        comboBox.stringValue = "feature/a"
        comboBox.selectItem(at: 1)

        #expect(ProjectFormsController.resolvedExistingWorkspaceBranchValue(existingBranchField: comboBox) == "feature/b")
    }

    @Test func existingWorkspaceBranchValueFallsBackToTypedComboBoxStringWhenNothingIsSelected() {
        let comboBox = NSComboBox()
        comboBox.stringValue = "release/candidate"

        #expect(ProjectFormsController.resolvedExistingWorkspaceBranchValue(existingBranchField: comboBox) == "release/candidate")
    }

    @Test func syncExistingWorkspaceBranchSelectionClearsStaleSelectedItemAfterEditingText() {
        let comboBox = NSComboBox()
        comboBox.addItems(withObjectValues: ["feature/a", "feature/b"])
        comboBox.selectItem(at: 0)
        comboBox.stringValue = "release/candidate"
        ProjectFormsController.syncExistingWorkspaceBranchSelection(existingBranchField: comboBox)

        #expect(ProjectFormsController.resolvedExistingWorkspaceBranchValue(existingBranchField: comboBox) == "release/candidate")
        #expect(comboBox.indexOfSelectedItem == -1)
    }
}
