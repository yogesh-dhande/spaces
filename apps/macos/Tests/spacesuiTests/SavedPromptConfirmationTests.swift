import Testing

@testable import spacesui

@Suite struct SavedPromptConfirmationTests {
    @Test func deleteNamesThePromptAndItsDevice() {
        let confirmation = SavedPromptDeleteConfirmation(promptTitle: "Find dead code", deviceName: "devbox")

        #expect(confirmation.title == "Delete \u{201C}Find dead code\u{201D}?")
        #expect(confirmation.message.contains("devbox"))
    }

    @Test func leavingASavedPromptSaysDiscardDoesNotDeleteIt() {
        let confirmation = SavedPromptUnsavedConfirmation(promptTitle: "Review this PR", isNew: false)

        #expect(confirmation.title == "Save changes to \u{201C}Review this PR\u{201D}?")
        #expect(confirmation.message.contains("does not delete"))
    }

    @Test func leavingANewPromptSaysDiscardThrowsItAway() {
        let untitled = SavedPromptUnsavedConfirmation(promptTitle: "  ", isNew: true)
        let titled = SavedPromptUnsavedConfirmation(promptTitle: "Summarize", isNew: true)

        #expect(untitled.title == "Save this new prompt?")
        #expect(titled.title == "Save \u{201C}Summarize\u{201D}?")
        #expect(titled.message.contains("throws it away"))
    }
}
