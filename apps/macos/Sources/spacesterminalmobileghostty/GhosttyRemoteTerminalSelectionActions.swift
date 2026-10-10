#if canImport(UIKit)
    import spacesterminalcore

    /// What the terminal view tells its owner about the selection the user makes by touch. The owner
    /// holds the selection (it follows the text across frames and into the replay); the view only reads
    /// cells under fingers and draws what the owner publishes.
    public struct GhosttyRemoteTerminalSelectionActions {
        /// A long press selected a word; the finger still down extends it.
        public let beginWordSelection: @MainActor (TerminalAbsoluteSelection) -> Void
        /// A finger took hold of a handle.
        public let beginHandleDrag: @MainActor (TerminalSelectionHandle) -> Void
        /// The drag's finger is over this cell.
        public let extendDrag: @MainActor (TerminalAbsoluteCell) -> Void
        /// The finger lifted; the selection stays.
        public let endDrag: @MainActor () -> Void
        /// A tap ends the selection.
        public let clear: @MainActor () -> Void
        /// One row of a drag held past an edge; the flag is whether it scrolls toward older rows.
        public let autoscroll: @MainActor (_ towardOlderRows: Bool) -> Void
        public let copy: @MainActor () -> Void
        public let selectAll: @MainActor () -> Void

        public init(
            beginWordSelection: @escaping @MainActor (TerminalAbsoluteSelection) -> Void,
            beginHandleDrag: @escaping @MainActor (TerminalSelectionHandle) -> Void, extendDrag: @escaping @MainActor (TerminalAbsoluteCell) -> Void,
            endDrag: @escaping @MainActor () -> Void, clear: @escaping @MainActor () -> Void,
            autoscroll: @escaping @MainActor (_ towardOlderRows: Bool) -> Void, copy: @escaping @MainActor () -> Void,
            selectAll: @escaping @MainActor () -> Void
        ) {
            self.beginWordSelection = beginWordSelection
            self.beginHandleDrag = beginHandleDrag
            self.extendDrag = extendDrag
            self.endDrag = endDrag
            self.clear = clear
            self.autoscroll = autoscroll
            self.copy = copy
            self.selectAll = selectAll
        }
    }
#endif
