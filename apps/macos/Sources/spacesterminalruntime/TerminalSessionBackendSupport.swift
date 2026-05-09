import Foundation
import spacesterminalcore
import spacesterminalghostty

public enum TerminalSessionBackendSupport {
    public static func isSupported(
        _ backend: TerminalSessionBackendKind, environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default, currentDirectoryPath: String? = nil
    ) -> Bool {
        switch backend {
        case .scriptPTY: true
        case .ghosttyEmbedded:
            if case .available = GhosttyEmbeddedLocator.resolve(
                environment: environment, fileManager: fileManager, currentDirectoryPath: currentDirectoryPath)
            {
                true
            } else {
                false
            }
        }
    }
}
