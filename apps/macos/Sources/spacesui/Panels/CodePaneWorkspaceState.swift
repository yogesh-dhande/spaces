import Foundation

/// Versioned client-local snapshot of one workspace's Editor surface. This is deliberately separate
/// from `CodePaneBridge.InitPayload`: the bridge describes a single page load, while this document
/// belongs to one `(device, workspace)` across controller replacement and app restart.
struct CodePaneWorkspaceState: Codable, Sendable {
    private static let currentVersion = 1

    let version: Int
    let mode: String
    let scope: CodePaneBridge.WorkspaceState.Scope
    let diffLayout: String
    let diffSelectedPath: String?
    let diffTreeExpandedPaths: [String]?
    let diffTreeSelectedPath: String?
    let fileTreeExpandedPaths: [String]
    let fileTreeSelectedPath: String?
    let editorSidebarMode: String
    let editorRecentPaths: [String]
    let diffScrollLine: Int?
    let diffScrollSide: String?
    let diffFocusedPath: String?
    let diffFocusedLine: Int?
    let diffFocusedSide: String?
    let editorScrollLine: Int?
    let editorFocusedLine: Int?
    let editorState: CodePaneBridge.EditorState?
    let diffEditorState: CodePaneBridge.DiffEditorState?
    let pendingReviewComments: [CodePaneBridge.ReviewCommentEntryPayload]?
    let selectedAgentSessionId: String?
    let pendingAgentLaunch: CodePaneBridge.PendingAgentLaunch?

    init(
        mode: CodePaneMode, scope: CodePaneBridge.WorkspaceState.Scope = .uncommitted, diffLayout: String = "unified",
        diffSelectedPath: String? = nil, diffTreeExpandedPaths: [String]? = nil, diffTreeSelectedPath: String? = nil,
        fileTreeExpandedPaths: [String] = [], fileTreeSelectedPath: String? = nil,
        editorSidebarMode: String = "files", editorRecentPaths: [String] = [], diffScrollLine: Int? = nil,
        diffScrollSide: String? = nil, diffFocusedPath: String? = nil, diffFocusedLine: Int? = nil, diffFocusedSide: String? = nil,
        editorScrollLine: Int? = nil, editorFocusedLine: Int? = nil,
        editorState: CodePaneBridge.EditorState?, diffEditorState: CodePaneBridge.DiffEditorState? = nil,
        pendingReviewComments: [CodePaneBridge.ReviewCommentEntryPayload]?, selectedAgentSessionId: String? = nil,
        pendingAgentLaunch: CodePaneBridge.PendingAgentLaunch? = nil
    ) {
        version = Self.currentVersion
        self.mode = mode.wireValue
        self.scope = scope
        self.diffLayout = diffLayout
        self.diffSelectedPath = diffSelectedPath
        self.diffTreeExpandedPaths = diffTreeExpandedPaths
        self.diffTreeSelectedPath = diffTreeSelectedPath
        self.fileTreeExpandedPaths = fileTreeExpandedPaths
        self.fileTreeSelectedPath = fileTreeSelectedPath
        self.editorSidebarMode = editorSidebarMode
        self.editorRecentPaths = editorRecentPaths
        self.diffScrollLine = diffScrollLine
        self.diffScrollSide = diffScrollSide
        self.diffFocusedPath = diffFocusedPath
        self.diffFocusedLine = diffFocusedLine
        self.diffFocusedSide = diffFocusedSide
        self.editorScrollLine = editorScrollLine
        self.editorFocusedLine = editorFocusedLine
        self.editorState = editorState
        self.diffEditorState = diffEditorState
        self.pendingReviewComments = pendingReviewComments
        self.selectedAgentSessionId = selectedAgentSessionId
        self.pendingAgentLaunch = pendingAgentLaunch
    }

    /// An unknown document version is ignored as a whole. The host must never attempt a partial
    /// restore of an evolving recovery format: a stale dirty merge base is less safe than reopening
    /// the workspace cleanly.
    var isCurrentVersion: Bool { version == Self.currentVersion }

    var codePaneMode: CodePaneMode { CodePaneMode(wireValue: mode) }

    var bridgePayload: CodePaneBridge.WorkspaceState {
        .init(
            mode: mode, scope: scope, diffLayout: diffLayout, diffSelectedPath: diffSelectedPath,
            diffTreeExpandedPaths: diffTreeExpandedPaths, diffTreeSelectedPath: diffTreeSelectedPath,
            fileTreeExpandedPaths: fileTreeExpandedPaths, fileTreeSelectedPath: fileTreeSelectedPath,
            editorSidebarMode: editorSidebarMode, editorRecentPaths: editorRecentPaths,
            diffScrollLine: diffScrollLine, diffScrollSide: diffScrollSide,
            diffFocusedPath: diffFocusedPath, diffFocusedLine: diffFocusedLine, diffFocusedSide: diffFocusedSide,
            editorScrollLine: editorScrollLine, editorFocusedLine: editorFocusedLine, editorState: editorState, diffEditorState: diffEditorState,
            pendingReviewComments: pendingReviewComments, selectedAgentSessionId: selectedAgentSessionId,
            pendingAgentLaunch: pendingAgentLaunch)
    }

    var isValid: Bool { CodePaneBridge.isValidWorkspaceState(bridgePayload) }
}
