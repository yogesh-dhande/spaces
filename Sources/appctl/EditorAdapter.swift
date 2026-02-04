import Foundation

public final class EditorAdapter {
    private let fileHeuristic: GitFileHeuristic

    public init(fileHeuristic: GitFileHeuristic = .init()) {
        self.fileHeuristic = fileHeuristic
    }

    public func open(editor: EditorKind, repoRoot: String) throws {
        switch editor {
        case .windsurf:
            try Shell.run(["surf", "."], cwd: repoRoot)
        case .vscode:
            try Shell.run(["code", "-r", "."], cwd: repoRoot)
        case .cursor:
            try Shell.run(["cursor", "-r", "."], cwd: repoRoot)
        }

        let files = fileHeuristic.relevantFiles(repoRoot: repoRoot, limit: 3)
        for file in files {
            switch editor {
            case .windsurf:
                _ = try? Shell.run(["surf", file])
            case .vscode:
                _ = try? Shell.run(["code", "-r", file])
            case .cursor:
                _ = try? Shell.run(["cursor", "-r", file])
            }
        }
    }
}
