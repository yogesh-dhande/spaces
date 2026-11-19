import Foundation

// Performance regression benchmark for the session index. Run it in release:
//   swift build -c release --product spacessessionsearchbench
//   .build/release/spacessessionsearchbench --synthetic [--scale N] [--json]
//   .build/release/spacessessionsearchbench --real [--json]
// It exits nonzero when a performance budget is missed.

do {
    let options = try BenchOptions(arguments: CommandLine.arguments)
    let report = try await BenchRunner.run(options)
    print(options.json ? try report.json() : report.table())
    exit(report.failedBudgets.isEmpty ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(2)
}
