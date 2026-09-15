import Foundation

/// What one cycle rotation covers, and the key its cursor, recent-target list, and frozen rotation
/// are filed under.
///
/// Workspace mode keeps one rotation per workspace, the state the cycle has always kept; every other
/// mode is a single rotation spanning every device and workspace, so it needs exactly one set of
/// that state. `.mode` therefore only ever carries a cross-device mode: Workspace mode resolves a
/// workspace first and cycles as `.workspace`.
enum WindowCycleScope: Sendable, Equatable {
    case workspace(String)
    case mode(WindowCycleMode)

    var key: String {
        switch self {
        case .workspace(let workspaceID): return "workspace:\(workspaceID)"
        case .mode(let mode): return "mode:\(mode.rawValue)"
        }
    }

    /// The mode this rotation belongs to, reported as `mode=` on the `window_cycle` perf line.
    var mode: WindowCycleMode {
        switch self {
        case .workspace: return .workspace
        case .mode(let mode): return mode
        }
    }

    var workspaceID: String? {
        switch self {
        case .workspace(let workspaceID): return workspaceID
        case .mode: return nil
        }
    }
}
