import Foundation

public final class GitFileHeuristic {
    public init() {}

    public func relevantFiles(repoRoot: String, limit: Int = 3) -> [String] {
        if let diffFiles = try? changedFiles(repoRoot: repoRoot), !diffFiles.isEmpty {
            return Array(diffFiles.prefix(limit))
        }

        if let recent = try? recentlyModifiedTrackedFiles(repoRoot: repoRoot, limit: limit), !recent.isEmpty {
            return recent
        }

        return []
    }

    private func changedFiles(repoRoot: String) throws -> [String] {
        let unstaged = try Shell.runAndCapture(["git", "-C", repoRoot, "diff", "--name-only"])
        let staged = try Shell.runAndCapture(["git", "-C", repoRoot, "diff", "--name-only", "--cached"])
        let names = (unstaged + "\n" + staged)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        let unique = Array(Set(names)).sorted()
        return unique
            .map { repoRoot + "/" + $0 }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .filter { !Self.excludedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    private func recentlyModifiedTrackedFiles(repoRoot: String, limit: Int) throws -> [String] {
        let tracked = try Shell.runAndCapture(["git", "-C", repoRoot, "ls-files"])
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        let fm = FileManager.default
        var entries: [(path: String, mtime: Date)] = []
        entries.reserveCapacity(tracked.count)

        for rel in tracked {
            let abs = repoRoot + "/" + rel
            let ext = URL(fileURLWithPath: abs).pathExtension.lowercased()
            if Self.excludedExtensions.contains(ext) {
                continue
            }
            guard let attrs = try? fm.attributesOfItem(atPath: abs),
                  let modified = attrs[.modificationDate] as? Date else {
                continue
            }
            entries.append((path: abs, mtime: modified))
        }

        return entries
            .sorted { $0.mtime > $1.mtime }
            .prefix(limit)
            .map(\.path)
    }

    private static let excludedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "zip", "gz", "pdf", "mp4", "mov", "lock"
    ]
}
