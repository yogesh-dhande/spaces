import Foundation
import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

@Suite struct SavedPromptsPaneModelTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func prompt(_ id: String, title: String = "Title", text: String = "Body", lastUsed: Date = now.addingTimeInterval(-3 * 3600))
        -> SpacesDeviceSavedPrompt
    {
        let stamp = TerminalSessionTimestamp.fractionalString(from: lastUsed)
        return SpacesDeviceSavedPrompt(id: id, title: title, text: text, createdAt: stamp, updatedAt: stamp, lastUsedAt: stamp)
    }

    private static func entry(_ id: String, device: String = "local", deviceName: String = "This Mac", title: String = "Title", text: String = "Body")
        -> SavedPromptLibrary.Entry
    { SavedPromptLibrary.Entry(deviceID: device, deviceName: deviceName, prompt: prompt(id, title: title, text: text)) }

    private func plan(
        _ model: SavedPromptsPaneModel, entries: [SavedPromptLibrary.Entry], filtered: [SavedPromptLibrary.Entry]? = nil, showsDevices: Bool = false
    ) -> [SavedPromptsPaneModel.Row] {
        model.renderPlan(filtered: filtered ?? entries, all: entries, deviceNameForDraft: "This Mac", showsDeviceColumn: showsDevices, now: Self.now)
    }

    @Test func everyDraftRowHasADeviceCellWhenTheTableHasTheColumn() {
        var orphaned = SavedPromptsPaneModel()
        _ = orphaned.attempt(.select(Self.entry("a", device: "gone")))
        orphaned.setText("mine")
        var fresh = SavedPromptsPaneModel()
        _ = fresh.attempt(.beginNew(deviceID: "gone"))

        for model in [orphaned, fresh] {
            let rows = model.renderPlan(filtered: [], all: [], deviceNameForDraft: nil, showsDeviceColumn: true, now: Self.now)
            #expect(rows.count == 1)
            #expect(rows.first?.deviceText != nil, "a missing cell would break the table's column count")
        }
    }

    @Test func theOpenRowHasNoPreviewAndItsCopyReadsCopyEditedOnlyWhileEdited() {
        let entries = [Self.entry("a", title: "Plan", text: "Body"), Self.entry("b", text: "Other")]
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(entries[0]))

        var rows = plan(model, entries: entries)
        #expect(rows.map(\.preview) == ["", "Other"])
        #expect(rows.map(\.copyTitle) == ["Copy", "Copy"])

        model.setText("Body, edited")
        rows = plan(model, entries: entries)
        #expect(rows.map(\.copyTitle) == ["Copy edited", "Copy"])

        model.markCopied("local/a")
        #expect(plan(model, entries: entries).first?.copyTitle == "Copied")
    }

    @Test func aNewDraftRowHasNoPreview() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))
        model.setText("Typed text")

        let rows = plan(model, entries: [])
        #expect(rows.first?.preview == "")
        #expect(rows.first?.copyTitle == "Copy edited")
    }

    // MARK: - Table

    @Test func theDeviceColumnAndPickerNeedMoreThanOnePairedDevice() {
        #expect(!SavedPromptsPaneModel.showsDeviceChoices(pairedDeviceCount: 1))
        #expect(SavedPromptsPaneModel.showsDeviceChoices(pairedDeviceCount: 2))
    }

    @Test func rowsShowTitleDeviceAndAgeOnlyWhenTheTableHasADeviceColumn() {
        let entries = [Self.entry("a", title: "Plan")]

        let single = plan(SavedPromptsPaneModel(), entries: entries)
        let several = plan(SavedPromptsPaneModel(), entries: entries, showsDevices: true)

        #expect(single.first?.deviceText == nil)
        #expect(several.first?.deviceText == "This Mac")
        #expect(single.first?.title == "Plan")
        #expect(single.first?.usedText == "3h")
    }

    @Test func thePreviewIsOneLineAndBounded() {
        #expect(SavedPromptsPaneModel.preview("Review this\n\nbranch   against\tmain") == "Review this branch against main")
        let long = String(repeating: "word ", count: 200)
        let preview = SavedPromptsPaneModel.preview(long)
        #expect(preview.hasSuffix("…"))
        #expect(preview.count <= 241)
    }

    @Test func theOpenPromptStaysListedWhenTheSearchHidesIt() {
        var model = SavedPromptsPaneModel()
        let open = Self.entry("open")
        let other = Self.entry("other")
        _ = model.attempt(.select(open))

        let rows = plan(model, entries: [open, other], filtered: [other])

        #expect(rows.map(\.key) == [open.id, other.id])
        #expect(rows.first?.isExpanded == true)
    }

    @Test func aNewDraftIsTheFirstRowAndNamedUntilTyped() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))

        #expect(plan(model, entries: [Self.entry("a")]).first?.title == "New prompt")
        model.setTitle("Summarize")
        let rows = plan(model, entries: [Self.entry("a")])
        #expect(rows.first?.title == "Summarize")
        #expect(rows.first?.isNewDraft == true)
        #expect(rows.count == 2)
    }

    @Test func newPromptsDefaultToThisMacThenTheFirstReachableDevice() {
        #expect(SavedPromptsPaneModel.defaultDeviceID(reachableDeviceIDs: ["remote", "local"], localDeviceID: "local") == "local")
        #expect(SavedPromptsPaneModel.defaultDeviceID(reachableDeviceIDs: ["remote"], localDeviceID: "local") == "remote")
        #expect(SavedPromptsPaneModel.defaultDeviceID(reachableDeviceIDs: [], localDeviceID: "local") == nil)
    }

    // MARK: - Unsaved edits

    @Test func selectingARowOpensItAndSelectingItAgainCollapsesIt() {
        var model = SavedPromptsPaneModel()
        let entry = Self.entry("a")

        #expect(model.attempt(.select(entry)) == .applied)
        #expect(model.expandedKey == entry.id)
        #expect(model.attempt(.select(entry)) == .applied)
        #expect(model.expandedKey == nil)
    }

    @Test func movesThatLeaveADirtyDraftNeedADecisionAndChangeNothing() {
        let first = Self.entry("a")
        let second = Self.entry("b")
        let actions: [SavedPromptsPaneAction] = [.select(second), .select(first), .collapse, .beginNew(deviceID: "local")]
        for action in actions {
            var model = SavedPromptsPaneModel()
            _ = model.attempt(.select(first))
            model.setText("edited")

            #expect(model.attempt(action) == .needsUnsavedDecision)
            #expect(model.expandedKey == first.id)
            #expect(model.draft?.text == "edited")
        }
    }

    @Test func deleteOnADirtyDraftGoesStraightToTheDeleteConfirmation() {
        var model = SavedPromptsPaneModel()
        let entry = Self.entry("a")
        _ = model.attempt(.select(entry))
        model.setText("edited")

        #expect(model.attempt(.delete) == .applied)
        #expect(model.expandedKey == entry.id, "cancelling the confirmation leaves the draft open")
        #expect(model.hasUnsavedEdits)
        #expect(model.draft?.text == "edited")
    }

    @Test func aCleanDraftMovesWithoutAsking() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(Self.entry("a")))
        model.setText("edited")
        model.setText("Body")

        #expect(!model.hasUnsavedEdits)
        #expect(model.attempt(.select(Self.entry("b"))) == .applied)
    }

    @Test func copyingDoesNotCleanAnEditedDraftButSavingAndDiscardingDo() {
        var model = SavedPromptsPaneModel()
        let entry = Self.entry("a")
        _ = model.attempt(.select(entry))
        model.setText("edited")

        model.markCopied(entry.id)
        #expect(model.hasUnsavedEdits, "Copy edited does not save")

        var saved = model
        saved.saveSucceeded(promptID: "a", deviceID: "local", title: "Title", text: "edited")
        #expect(!saved.hasUnsavedEdits)
        #expect(saved.expandedKey == entry.id, "a saved prompt stays open")

        model.discardDraft(entries: [entry])
        #expect(!model.hasUnsavedEdits)
        #expect(model.draft?.text == "Body")
    }

    @Test func textTypedWhileASaveWasInFlightStaysAnEdit() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(Self.entry("a")))
        model.setText("saved text")
        model.setText("saved text and more")

        model.saveSucceeded(promptID: "a", deviceID: "local", title: "Title", text: "saved text")

        #expect(model.hasUnsavedEdits)
    }

    @Test func textTypedWhileACreateWasInFlightBecomesAnEditOfTheCreatedPrompt() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))
        model.setTitle("T")
        model.setText("saved text")
        model.setText("saved text and more")

        model.createSucceeded(created: Self.prompt("new", title: "T", text: "saved text"), deviceID: "local", title: "T", text: "saved text")

        #expect(model.draft?.promptID == "new")
        #expect(model.draft?.text == "saved text and more")
        #expect(model.hasUnsavedEdits)
    }

    @Test func aSaveResultNeverTouchesAReplacementDraft() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(Self.entry("b")))
        model.setText("typed in b")

        model.saveSucceeded(promptID: "a", deviceID: "local", title: "Title", text: "typed in b")
        #expect(model.hasUnsavedEdits, "a save of another prompt leaves this draft dirty")

        var newDraft = SavedPromptsPaneModel()
        _ = newDraft.attempt(.select(Self.entry("b")))
        newDraft.createSucceeded(created: Self.prompt("new"), deviceID: "local", title: "Title", text: "Body")
        #expect(newDraft.draft?.promptID == "b", "a create result does not close an existing prompt's editor")
    }

    @Test func aDeleteResultClosesOnlyTheDeletedPromptsEditor() {
        var model = SavedPromptsPaneModel()
        let b = Self.entry("b")
        _ = model.attempt(.select(b))
        model.setText("typed in b")

        model.closeDraft(promptID: "a", deviceID: "local")
        #expect(model.expandedKey == b.id)
        #expect(model.hasUnsavedEdits)

        model.closeDraft(promptID: "b", deviceID: "other")
        #expect(model.expandedKey == b.id, "the same id on another device is a different prompt")

        model.closeDraft(promptID: "b", deviceID: "local")
        #expect(model.draft == nil)
    }

    @Test func savingANewDraftClosesItAndDiscardingOneDropsIt() {
        var saved = SavedPromptsPaneModel()
        _ = saved.attempt(.beginNew(deviceID: "local"))
        saved.setTitle("T")
        saved.setText("B")
        saved.createSucceeded(created: Self.prompt("new", title: "T", text: "B"), deviceID: "local", title: "T", text: "B")
        #expect(saved.draft == nil)

        var discarded = SavedPromptsPaneModel()
        _ = discarded.attempt(.beginNew(deviceID: "local"))
        discarded.setText("B")
        discarded.discardDraft(entries: [])
        #expect(discarded.draft == nil)
    }

    @Test func aNewDraftNeedsATitleAndNonBlankTextWithinTheSizeCap() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))
        #expect(model.draft?.validationError != nil)
        model.setTitle("T")
        #expect(model.draft?.validationError != nil, "blank text")
        model.setText("   \n")
        #expect(model.draft?.validationError != nil, "whitespace-only text")
        model.setText("B")
        #expect(model.draft?.validationError == nil)
        model.setText(String(repeating: "x", count: SpacesDeviceSavedPrompt.maximumTextBytes + 1))
        #expect(model.draft?.validationError == SpacesDeviceSavedPrompt.tooLongMessage)
    }

    @Test func editingClearsTheErrorLine() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))
        model.setError("Give the prompt a title.")

        model.setTitle("T")

        #expect(model.draft?.error == nil)
    }

    @Test func onlyANewDraftCanChooseItsDevice() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))
        model.setDevice("remote")
        #expect(model.draft?.deviceID == "remote")

        var existing = SavedPromptsPaneModel()
        _ = existing.attempt(.select(Self.entry("a")))
        existing.setDevice("remote")
        #expect(existing.draft?.deviceID == "local")
    }

    // MARK: - Library changes

    @Test func aRemoteEditRefreshesACleanDraft() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(Self.entry("a", text: "old")))

        model.libraryChanged(entries: [Self.entry("a", title: "Renamed", text: "new")])

        #expect(model.draft?.title == "Renamed")
        #expect(model.draft?.text == "new")
        #expect(!model.hasUnsavedEdits)
    }

    @Test func aRemoteEditKeepsADirtyDraftsTypedText() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(Self.entry("a", text: "old")))
        model.setText("mine")

        model.libraryChanged(entries: [Self.entry("a", text: "theirs")])

        #expect(model.draft?.text == "mine")
        #expect(model.hasUnsavedEdits)
    }

    @Test func aPromptDeletedElsewhereClosesACleanDraft() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.select(Self.entry("a")))

        model.libraryChanged(entries: [])

        #expect(model.draft == nil)
    }

    @Test func aPromptDeletedElsewhereKeepsADirtyDraftOpenWithAnError() {
        var model = SavedPromptsPaneModel()
        let entry = Self.entry("a")
        _ = model.attempt(.select(entry))
        model.setText("mine")

        model.libraryChanged(entries: [])

        #expect(model.draft?.text == "mine")
        #expect(model.draft?.error != nil)
        let rows = plan(model, entries: [])
        #expect(rows.map(\.key) == [entry.id], "the editor stays on screen so the text can still be copied")
    }

    @Test func aNewDraftSurvivesLibraryChanges() {
        var model = SavedPromptsPaneModel()
        _ = model.attempt(.beginNew(deviceID: "local"))
        model.setTitle("T")

        model.libraryChanged(entries: [Self.entry("a")])

        #expect(model.draft?.title == "T")
    }

    // MARK: - Copied

    @Test func theCopiedMarkIsPerRowAndClearsOnlyItsOwnRow() {
        var model = SavedPromptsPaneModel()
        let a = Self.entry("a")
        let b = Self.entry("b")
        model.markCopied(a.id)
        model.clearCopied(b.id)

        #expect(plan(model, entries: [a, b]).map(\.showsCopied) == [true, false])

        model.clearCopied(a.id)
        #expect(plan(model, entries: [a, b]).map(\.showsCopied) == [false, false])
    }

    // MARK: - In-place rendering

    private static func row(
        _ key: String, title: String = "Title", preview: String = "Body", device: String? = nil, used: String = "3h", expanded: Bool = false,
        isNew: Bool = false, copied: Bool = false, edited: Bool = false
    ) -> SavedPromptsPaneModel.Row {
        SavedPromptsPaneModel.Row(
            key: key, title: title, preview: preview, deviceText: device, usedText: used, isExpanded: expanded, isNewDraft: isNew,
            showsCopied: copied, isEdited: edited)
    }

    private func canApply(_ old: [SavedPromptsPaneModel.Row], _ new: [SavedPromptsPaneModel.Row], oldDevices: Bool = false, newDevices: Bool = false)
        -> Bool
    { SavedPromptsPaneModel.canApplyInPlace(from: (old, oldDevices), to: (new, newDevices)) }

    @Test func identicalPlansApplyInPlace() {
        let rows = [Self.row("a"), Self.row("b", expanded: true)]
        #expect(canApply(rows, rows))
    }

    @Test func ageCopyAndOpenTitleChangesApplyInPlace() {
        let old = [Self.row("a"), Self.row("b", title: "Old", preview: "", expanded: true)]
        let new = [
            Self.row("a", used: "4h", copied: true),
            Self.row("b", title: "Typed title", preview: "", used: "1m", expanded: true, copied: true, edited: true),
        ]
        #expect(canApply(old, new))
    }

    @Test func aChangedRowSetOrderTitleOrExpansionNeedsARebuild() {
        let base = [Self.row("a"), Self.row("b")]
        #expect(!canApply(base, [Self.row("a")]))
        #expect(!canApply(base, base + [Self.row("c")]))
        #expect(!canApply(base, [Self.row("b"), Self.row("a")]))
        #expect(!canApply(base, [Self.row("a", title: "Renamed"), Self.row("b")]))
        #expect(!canApply(base, [Self.row("a", preview: "Other"), Self.row("b")]))
        #expect(!canApply(base, [Self.row("a", expanded: true, isNew: false), Self.row("b")]))
        #expect(!canApply([Self.row("a", expanded: true)], [Self.row("a", expanded: true, isNew: true)]))
        #expect(!canApply(base, [Self.row("a"), Self.row("b", title: "Renamed")]))
    }

    @Test func aDeviceColumnChangeNeedsARebuild() {
        #expect(!canApply([Self.row("a")], [Self.row("a", device: "This Mac")], oldDevices: false, newDevices: true))
        #expect(!canApply([Self.row("a", device: "This Mac")], [Self.row("a", device: "Mac Studio")], oldDevices: true, newDevices: true))
    }
}
