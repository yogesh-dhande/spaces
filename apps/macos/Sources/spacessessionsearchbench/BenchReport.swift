import Foundation

struct BenchReport: Codable {
    struct Initial: Codable {
        var wallSeconds = 0.0
        var cpuSeconds = 0.0
        var cpuPerWall = 0.0
        var peakMemoryBytes: Int64 = 0
        var peakFootprintBytes: Int64 = 0
        /// Peak memory before indexing started (corpus generation, process start); what the index adds is the difference.
        var peakMemoryBeforeIndexBytes: Int64 = 0
        var indexFileBytes: Int64 = 0
        var sessionsDiscovered = 0
        var sessionsRead = 0
        var sessionsFailed = 0
        var turnsWritten = 0
        /// Searchable sessions and turns per agent after the build, to compare what gets indexed between versions.
        var sessionsPerAgent: [String: Int] = [:]
        var turnsPerAgent: [String: Int] = [:]
    }

    struct NoChange: Codable {
        var wallMilliseconds = 0.0
        var cpuMilliseconds = 0.0
        var cpuPercentOfOneCoreAt60sInterval = 0.0
        var sessionsRead = 0
        var filesStatted = 0
        var directoriesStatted = 0
        var directoriesListed = 0
    }

    struct Append: Codable {
        var linesAppended = 0
        var turnsWritten = 0
        var wallMilliseconds = 0.0
        var cpuMilliseconds = 0.0
    }

    struct QueryRow: Codable {
        var query: String
        /// Sessions on the first page; `hasMore` when further pages exist.
        var results: Int
        var hasMore: Bool
        var p50Milliseconds: Double
        var p95Milliseconds: Double
    }

    struct Distribution: Codable {
        var runs = 0
        var p50Milliseconds = 0.0
        var p95Milliseconds = 0.0
        var maxMilliseconds = 0.0

        init() {}
        init(_ samples: LatencySamples) {
            runs = samples.count
            p50Milliseconds = samples.p50
            p95Milliseconds = samples.p95
            maxMilliseconds = samples.max
        }
    }

    struct Budget: Codable {
        var name: String
        var limit: String
        var actual: String
        var passed: Bool
    }

    var mode = ""
    var scale: Double?
    var corpus: CorpusStats?
    var initial = Initial()
    var noChange = NoChange()
    var noChangePasses = ""
    var append: Append?
    var queries: [QueryRow] = []
    var allQueries = Distribution()
    var emptyQuery = Distribution()
    var secondPage = Distribution()
    var budgets: [Budget] = []

    var failedBudgets: [Budget] { budgets.filter { !$0.passed } }

    /// The budgets a future change must stay inside.
    mutating func evaluateBudgets() {
        func milliseconds(_ value: Double) -> String { String(format: "%.2f ms", value) }
        budgets = [
            Budget(name: "query p95", limit: "< 100 ms", actual: milliseconds(allQueries.p95Milliseconds), passed: allQueries.p95Milliseconds < 100),
            Budget(
                name: "empty-query listing p95", limit: "< 100 ms", actual: milliseconds(emptyQuery.p95Milliseconds),
                passed: emptyQuery.p95Milliseconds < 100),
            Budget(
                name: "Show-more page 2 p95", limit: "< 100 ms", actual: milliseconds(secondPage.p95Milliseconds),
                passed: secondPage.p95Milliseconds < 100),
            Budget(
                name: "no-change refresh CPU at 60 s poll", limit: "< 0.1% of one core",
                actual: String(format: "%.3f%%", noChange.cpuPercentOfOneCoreAt60sInterval), passed: noChange.cpuPercentOfOneCoreAt60sInterval < 0.1),
            // Compared at the two decimals it is printed with: user plus system time of a single busy thread
            // can exceed wall time by clock granularity.
            Budget(
                name: "initial index CPU / wall", limit: "<= 1.00", actual: String(format: "%.2f", initial.cpuPerWall),
                passed: (initial.cpuPerWall * 100).rounded() / 100 <= 1.0),
        ]
    }

    // MARK: - Output

    func table() -> String {
        func megabytes(_ bytes: Int64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        var lines: [String] = []
        lines.append("spacessessionsearchbench: \(mode)" + (scale.map { " (scale \($0))" } ?? ""))
        if let corpus {
            lines.append(
                "corpus: \(corpus.sessions) sessions, \(megabytes(corpus.storeBytes)) of store bytes, \(megabytes(corpus.searchableTextBytes)) searchable text, \(corpus.compressedCodexSessions) compressed Codex rollouts"
            )
            if let note = corpus.note { lines.append("note: \(note)") }
        }
        lines.append("")
        lines.append("Initial index (background priority, one thread)")
        lines.append(
            String(
                format: "  sessions discovered / read / failed   %d / %d / %d", initial.sessionsDiscovered, initial.sessionsRead,
                initial.sessionsFailed))
        lines.append("  turns indexed                         \(initial.turnsWritten)")
        for agent in initial.sessionsPerAgent.keys.sorted() {
            lines.append(
                "    \(agent.padding(toLength: 12, withPad: " ", startingAt: 0)) \(initial.sessionsPerAgent[agent] ?? 0) sessions, \(initial.turnsPerAgent[agent] ?? 0) turns"
            )
        }
        lines.append(String(format: "  wall time                             %.2f s", initial.wallSeconds))
        lines.append(String(format: "  CPU time (user+sys)                   %.2f s", initial.cpuSeconds))
        lines.append(String(format: "  CPU / wall                            %.2f", initial.cpuPerWall))
        lines.append(
            "  peak memory (process high-water)      \(megabytes(initial.peakMemoryBytes)) (before indexing: \(megabytes(initial.peakMemoryBeforeIndexBytes)))"
        )
        if initial.peakFootprintBytes > 0 { lines.append("  peak physical footprint               \(megabytes(initial.peakFootprintBytes))") }
        lines.append("  index file size                       \(megabytes(initial.indexFileBytes))")
        lines.append("")
        lines.append("Refresh with nothing changed")
        lines.append("  median of \(noChangePasses)")
        lines.append(
            String(
                format: "  wall %.1f ms, CPU %.1f ms, sessions read %d", noChange.wallMilliseconds, noChange.cpuMilliseconds, noChange.sessionsRead))
        lines.append(
            "  files stat-ed \(noChange.filesStatted), directories stat-ed \(noChange.directoriesStatted), directories listed \(noChange.directoriesListed)"
        )
        lines.append(String(format: "  implied CPU at a 60 s poll interval   %.3f%% of one core", noChange.cpuPercentOfOneCoreAt60sInterval))
        lines.append("")
        lines.append("Incremental append")
        if let append {
            lines.append(
                String(
                    format: "  %d lines appended to one session: wall %.1f ms, CPU %.1f ms, turns written %d", append.linesAppended,
                    append.wallMilliseconds, append.cpuMilliseconds, append.turnsWritten))
        } else {
            lines.append("  skipped (the stores are read-only in this mode)")
        }
        lines.append("")
        lines.append("Query latency")
        let width = max(12, (queries.map(\.query.count).max() ?? 0) + 2)
        lines.append("  " + "query".padding(toLength: width, withPad: " ", startingAt: 0) + "results      p50 ms      p95 ms")
        for row in queries {
            let results = "\(row.results)\(row.hasMore ? "+" : "")"
            lines.append(
                "  " + row.query.padding(toLength: width, withPad: " ", startingAt: 0) + String(repeating: " ", count: max(0, 7 - results.count))
                    + results + String(format: "  %10.2f  %10.2f", row.p50Milliseconds, row.p95Milliseconds))
        }
        lines.append(
            String(
                format: "  all queries pooled (%d runs): p50 %.2f ms, p95 %.2f ms, max %.2f ms", allQueries.runs, allQueries.p50Milliseconds,
                allQueries.p95Milliseconds, allQueries.maxMilliseconds))
        lines.append(
            String(
                format: "  empty-query listing (%d runs): p50 %.2f ms, p95 %.2f ms, max %.2f ms", emptyQuery.runs, emptyQuery.p50Milliseconds,
                emptyQuery.p95Milliseconds, emptyQuery.maxMilliseconds))
        lines.append(
            String(
                format: "  Show-more page 2 (%d runs): p50 %.2f ms, p95 %.2f ms, max %.2f ms", secondPage.runs, secondPage.p50Milliseconds,
                secondPage.p95Milliseconds, secondPage.maxMilliseconds))
        lines.append("")
        lines.append("Budgets")
        for budget in budgets { lines.append("  \(budget.passed ? "PASS" : "FAIL")  \(budget.name): \(budget.actual) (limit \(budget.limit))") }
        if !failedBudgets.isEmpty { lines.append("FAILED budgets: " + failedBudgets.map(\.name).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
