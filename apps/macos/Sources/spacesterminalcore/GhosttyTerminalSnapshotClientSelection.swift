import Foundation

extension GhosttyTerminalSnapshot {
    /// This snapshot with `selection` replaced by the client's own selection projected onto it (nil when
    /// the client has none or it does not reach this frame), so a consumer paints its selection through the
    /// same pipeline that paints a host-supplied one. Apply it before a viewport crop: the crop rebases
    /// `selection` along with the rest of the snapshot.
    public func withClientSelection(_ clientSelection: TerminalAbsoluteSelection?) -> GhosttyTerminalSnapshot {
        replacingSelection(with: clientSelection?.projection(onto: self))
    }

    private func replacingSelection(with selection: GhosttyTerminalSelectionRange?) -> GhosttyTerminalSnapshot {
        GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: cursorColumn, cursorRow: cursorRow, cursorVisible: cursorVisible,
            defaultForegroundRGB: defaultForegroundRGB, defaultBackgroundRGB: defaultBackgroundRGB, cells: cells, clusters: clusters,
            linkURLs: linkURLs, mouseReportingActive: mouseReportingActive, mouseShiftCapture: mouseShiftCapture,
            alternateScreenActive: alternateScreenActive, selection: selection, scrollbarTotal: scrollbarTotal, scrollbarOffset: scrollbarOffset,
            historyRowBase: historyRowBase, historyEpoch: historyEpoch)
    }
}
