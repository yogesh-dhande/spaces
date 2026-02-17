import Foundation
import Yams

public final class ConfigStore {
    public static let defaultFilename = "config.yaml"
    public let path: String

    public init(path: String) { self.path = path }

    public func load() throws -> AppConfig {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            let config = AppConfig(editor: nil, portRange: PortRange(start: 20000, end: 30000))
            try save(config)
            return config
        }
        let text = try String(contentsOf: url)
        let decoder = YAMLDecoder()
        var config = try decoder.decode(AppConfig.self, from: text)
        if config.portRange.start <= 0 || config.portRange.end <= 0 || config.portRange.end <= config.portRange.start {
            config.portRange = PortRange(start: 20000, end: 30000)
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        let encoder = YAMLEncoder()
        let text = try encoder.encode(config)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func defaultPath() throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".muxy", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(defaultFilename).path
    }
}
