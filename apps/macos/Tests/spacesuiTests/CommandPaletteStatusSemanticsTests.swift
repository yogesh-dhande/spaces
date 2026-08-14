import Testing
import spacesclientcore

@testable import spacesui

struct CommandPaletteStatusSemanticsTests {
    @Test func processStatusesUseSidebarAttentionSemantics() {
        #expect(CommandPaletteItem.Status.process(.running).attentionStatus == .working)
        #expect(CommandPaletteItem.Status.process(.exited).attentionStatus == .failed)
        #expect(CommandPaletteItem.Status.process(.idle).attentionStatus == .inactive)
    }

    @Test func agentStatusesUseSidebarAttentionSemantics() {
        #expect(CommandPaletteItem.Status.agent(.spinning).attentionStatus == .working)
        #expect(CommandPaletteItem.Status.agent(.waiting).attentionStatus == .blocked)
        #expect(CommandPaletteItem.Status.agent(.done).attentionStatus == .done)
        #expect(CommandPaletteItem.Status.agent(.idle).attentionStatus == .inactive)
        #expect(CommandPaletteItem.Status.agent(.exited).attentionStatus == .inactive)
    }
}
