import Foundation

public enum ExecutableTool: Sendable {
    case tmux
    case yabai
    case git

    var commandName: String {
        switch self {
        case .tmux: "tmux"
        case .yabai: "yabai"
        case .git: "git"
        }
    }

    var preferredAbsolutePaths: [String] {
        switch self {
        case .tmux: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
        case .yabai: ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai", "/opt/local/bin/yabai", "/usr/bin/yabai"]
        case .git: ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git"]
        }
    }
}

public enum ExecutableLocator {
    public static func resolve(_ tool: ExecutableTool, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        resolve(commandName: tool.commandName, preferredAbsolutePaths: tool.preferredAbsolutePaths, environment: environment)
    }

    static func resolve(commandName: String, preferredAbsolutePaths: [String], environment: [String: String]) -> String? {
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        let mergedPATH = mergedPATHValue(environment: environment)
        for directory in mergedPATH.split(separator: ":").map(String.init) where !directory.isEmpty {
            append(URL(fileURLWithPath: directory).appending(path: commandName).path)
        }

        for path in preferredAbsolutePaths { append(path) }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        return nil
    }

    private static func mergedPATHValue(environment: [String: String]) -> String {
        let inherited = environment["PATH"] ?? ""
        let defaults = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        var seen = Set<String>()
        var paths: [String] = []

        for component in inherited.split(separator: ":").map(String.init) + defaults where !component.isEmpty {
            if seen.insert(component).inserted { paths.append(component) }
        }

        return paths.joined(separator: ":")
    }
}
