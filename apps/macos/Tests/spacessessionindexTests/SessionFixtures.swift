import Foundation

@testable import spacessessionindex

enum SessionFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    /// A copy of fixture `relativePath` in a fresh temporary directory, for tests that append to it.
    static func writableCopy(of relativePath: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spacessessionindex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url(relativePath).lastPathComponent)
        try FileManager.default.copyItem(at: url(relativePath), to: destination)
        return destination
    }

    static func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func stat(_ url: URL, kind: AgentSessionFile.Kind) throws -> AgentSessionFile { try AgentSessionFile.stat(url, kind: kind) }

    static func texts(_ result: AgentSessionReadResult, role: AgentSessionMessage.Role? = nil) -> [String] {
        result.messages.filter { role == nil || $0.role == role }.map(\.text)
    }
}
