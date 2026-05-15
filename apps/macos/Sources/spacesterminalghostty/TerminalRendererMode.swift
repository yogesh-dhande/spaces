import Foundation
import spacesterminalcore

public enum TerminalRendererMode: Sendable, Equatable {
    case ghosttyEmbedded(GhosttyEmbeddedPaths)
    case shellFallback(reason: String)

    public var statusSummary: String {
        switch self {
        case .ghosttyEmbedded: "Renderer: libghostty"
        case .shellFallback(let reason): "Renderer: shell fallback (\(reason))"
        }
    }
}

public enum TerminalRendererResolver {
    public static func resolveGhosttyEmbeddedMode(
        backend: TerminalSessionBackendKind, environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default,
        currentDirectoryPath: String? = nil
    ) -> TerminalRendererMode {
        switch GhosttyEmbeddedLocator.resolve(environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath) {
        case .available(let paths): return .ghosttyEmbedded(paths)
        case .unavailable(let reason): return .shellFallback(reason: reason)
        }
    }
}
