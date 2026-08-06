/// A single step of the macOS terminal text zoom, applied to ``TerminalTextSize``.
public enum TerminalTextZoomCommand: Equatable, Sendable {
    case zoomIn
    case zoomOut
}
