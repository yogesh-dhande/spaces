import Foundation

public struct SeedPayload: Codable {
    public let projects: [Project]
    public let streams: [Stream]

    public init(projects: [Project], streams: [Stream]) {
        self.projects = projects
        self.streams = streams
    }
}

public enum SeedLoader {
    public static func importJSON(filePath: String, store: SQLiteStore) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        let payload = try JSONDecoder().decode(SeedPayload.self, from: data)

        for project in payload.projects {
            try store.upsert(project: project)
        }
        for stream in payload.streams {
            try store.upsert(stream: stream)
        }
    }
}
