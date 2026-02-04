import Foundation

public enum EditorKind: String, Codable, Sendable {
    case windsurf
    case vscode
    case cursor

    public var bundleID: String {
        switch self {
        case .windsurf:
            return "com.exafunction.windsurf"
        case .vscode:
            return "com.microsoft.VSCode"
        case .cursor:
            return "com.todesktop.230313mzl4w4u92"
        }
    }

    public var launchCommand: [String] {
        switch self {
        case .windsurf:
            return ["surf"]
        case .vscode:
            return ["code"]
        case .cursor:
            return ["cursor"]
        }
    }
}

public enum BrowserKind: String, Codable, Sendable {
    case chrome

    public var bundleID: String {
        "com.google.Chrome"
    }
}

public enum TerminalKind: String, Codable, Sendable {
    case terminal

    public var bundleID: String {
        "com.apple.Terminal"
    }
}
