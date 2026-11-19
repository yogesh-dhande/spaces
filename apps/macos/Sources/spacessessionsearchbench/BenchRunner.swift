import Foundation
import spacessessionindex
import spacesterminalcore

struct BenchOptions {
    enum Source {
        case synthetic(scale: Double)
        case real
    }

    let source: Source
    let json: Bool

    static let usage = "usage: spacessessionsearchbench (--synthetic [--scale N] | --real) [--json]"

    init(arguments: [String]) throws {
        var synthetic = false
        var real = false
        var scale = 1.0
        var json = false
        var remaining = arguments.dropFirst()
        while let argument = remaining.popFirst() {
            switch argument {
            case "--synthetic": synthetic = true
            case "--real": real = true
            case "--json": json = true
            case "--scale":
                guard let value = remaining.popFirst().flatMap(Double.init), value > 0 else {
                    throw BenchError("--scale needs a positive number\n\(Self.usage)")
                }
                scale = value
            default: throw BenchError("unknown argument \(argument)\n\(Self.usage)")
            }
        }
        guard synthetic != real else { throw BenchError("choose exactly one of --synthetic and --real\n\(Self.usage)") }
        self.source = real ? .real : .synthetic(scale: scale)
        self.json = json
    }
}

/// Indexes a corpus exactly as the daemon would (one background-priority thread), then measures the
/// no-change pass, an append, and query latency.
enum BenchRunner {
    /// The realistic set, plus common words filtered to the rarest agents: those force the deepest scans,
    /// because the newest-first scan has to walk past every match from the other agents.
    private static let queries: [(String, Set<CodingAgent>?)] = [
        ("the", nil), ("test", nil), ("error", nil), ("migration", nil), ("fix failing test", nil), ("database migration schema", nil),
        ("error handling", nil), ("\"unit test\"", nil), ("migr", nil), ("zzqxnomatch", nil), ("the", [.opencode]), ("test", [.pi]),
        ("error handling", [.amp, .copilot]), ("the", [.claudeCode]), ("", [.opencode]),
    ]
    private static let measuredRunsPerQuery = 20
    private static let noChangeRuns = 5
    private static let maxNoChangeAttempts = 60
    private static let appendedPairs = 10

    static func run(_ options: BenchOptions) async throws -> BenchReport {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "spacessessionsearchbench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var report = BenchReport()
        var corpus: SyntheticCorpus?
        let locations: AgentSessionStoreLocations
        switch options.source {
        case .synthetic(let scale):
            var generator = SyntheticCorpus(
                locations: AgentSessionStoreLocations(home: workDirectory.appendingPathComponent("home", isDirectory: true)), scale: scale)
            report.mode = "synthetic"
            report.scale = scale
            report.corpus = try generator.generate()
            locations = generator.locations
            corpus = generator
        case .real:
            report.mode = "real (read-only against \(FileManager.default.homeDirectoryForCurrentUser.path))"
            locations = AgentSessionStoreLocations(home: FileManager.default.homeDirectoryForCurrentUser)
        }

        let indexURL = workDirectory.appendingPathComponent("index/sessions.db")
        let index = try AgentSessionIndex(indexURL: indexURL, locations: locations)

        // Initial build.
        report.initial.peakMemoryBeforeIndexBytes = ResourceUsage.peakMemoryBytes()
        let initial = try await ResourceUsage.measure { try await index.refreshInBackground() }
        report.initial.wallSeconds = initial.wall
        report.initial.cpuSeconds = initial.cpu
        report.initial.cpuPerWall = initial.wall > 0 ? initial.cpu / initial.wall : 0
        report.initial.peakMemoryBytes = ResourceUsage.peakMemoryBytes()
        report.initial.peakFootprintBytes = ResourceUsage.peakFootprintBytes()
        report.initial.indexFileBytes = fileSize(indexURL.path) + fileSize(indexURL.path + "-wal")
        report.initial.sessionsDiscovered = initial.value.sessionsDiscovered
        report.initial.sessionsRead = initial.value.sessionsRead
        report.initial.sessionsFailed = initial.value.sessionsFailed
        report.initial.turnsWritten = initial.value.turnsWritten
        let statistics = try index.statistics()
        for (agent, count) in statistics.sessions {
            report.initial.sessionsPerAgent[agent.rawValue] = count
            report.initial.turnsPerAgent[agent.rawValue] = statistics.turns[agent] ?? 0
        }

        // Refresh with nothing changed: the median of a few passes.
        var passes: [(wall: Double, cpu: Double, summary: AgentSessionRefreshSummary)] = []
        // A store written to while the bench runs (a live agent on the real machine) makes a pass read that
        // session, and such a pass is not a no-change pass. Passes repeat until enough quiet ones are seen.
        var attempts = 0
        while passes.filter({ $0.summary.sessionsRead == 0 }).count < noChangeRuns && attempts < maxNoChangeAttempts {
            attempts += 1
            let pass = try await ResourceUsage.measure { try await index.refreshInBackground() }
            passes.append((pass.wall, pass.cpu, pass.value))
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let quiet = passes.filter { $0.summary.sessionsRead == 0 }
        report.noChangePasses = "\(quiet.count) quiet of \(attempts) passes"
        let measured = quiet.isEmpty ? passes : quiet
        let median = measured.sorted { $0.cpu < $1.cpu }[measured.count / 2]
        report.noChange = BenchReport.NoChange(
            wallMilliseconds: median.wall * 1000, cpuMilliseconds: median.cpu * 1000, cpuPercentOfOneCoreAt60sInterval: median.cpu / 60 * 100,
            sessionsRead: passes.map(\.summary.sessionsRead).max() ?? 0, filesStatted: median.summary.filesStatted,
            directoriesStatted: median.summary.directoriesStatted, directoriesListed: median.summary.directoriesListed)

        // Append to one session and refresh.
        if let corpus, let transcript = corpus.firstClaudeTranscript {
            var text = ""
            let now = Date()
            for pair in 0..<appendedPairs {
                text +=
                    corpus.claudeLine(
                        role: "user", text: "appended question number \(pair) about the build", at: now.addingTimeInterval(Double(pair))) + "\n"
                text +=
                    corpus.claudeLine(
                        role: "assistant", text: "appended answer number \(pair) about the build", at: now.addingTimeInterval(Double(pair) + 0.5))
                    + "\n"
            }
            let handle = try FileHandle(forWritingTo: transcript)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            let pass = try await ResourceUsage.measure { try await index.refreshInBackground() }
            report.append = BenchReport.Append(
                linesAppended: appendedPairs * 2, turnsWritten: pass.value.turnsWritten, wallMilliseconds: pass.wall * 1000,
                cpuMilliseconds: pass.cpu * 1000)
        }

        // Queries.
        var pooled = LatencySamples()
        for (query, agents) in queries {
            let first = try index.search(query: query, agents: agents)
            var samples = LatencySamples()
            for _ in 0..<measuredRunsPerQuery { samples.add(try time { _ = try index.search(query: query, agents: agents) }) }
            let label = query + (agents.map { " [\($0.map(\.rawValue).sorted().joined(separator: ","))]" } ?? "")
            report.queries.append(
                BenchReport.QueryRow(
                    query: label, results: first.results.count, hasMore: first.hasMore, p50Milliseconds: samples.p50, p95Milliseconds: samples.p95))
            pooled.add(contentsOf: samples)
        }
        report.allQueries = BenchReport.Distribution(pooled)

        var empty = LatencySamples()
        _ = try index.search(query: "")
        for _ in 0..<(measuredRunsPerQuery * 2) { empty.add(try time { _ = try index.search(query: "") }) }
        report.emptyQuery = BenchReport.Distribution(empty)

        var secondPage = LatencySamples()
        for query in ["the", "test", ""] {
            _ = try index.search(query: query, page: 1)
            for _ in 0..<measuredRunsPerQuery { secondPage.add(try time { _ = try index.search(query: query, page: 1) }) }
        }
        report.secondPage = BenchReport.Distribution(secondPage)

        report.evaluateBudgets()
        return report
    }

    private static func time(_ body: () throws -> Void) throws -> Double {
        let start = ResourceUsage.wallSeconds()
        try body()
        return (ResourceUsage.wallSeconds() - start) * 1000
    }

    private static func fileSize(_ path: String) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
