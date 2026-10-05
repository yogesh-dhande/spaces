import Dispatch
import Foundation
import Testing

@Suite("Test process crash report")
struct TestCrashReportTests {
    // libdispatch's client crash is a `brk` on arm64 and a `ud2` on x86_64.
    #if arch(x86_64)
    private static let dispatchTrapSignal = (number: SIGILL, line: "spaces-test-crash: signal 4 (SIGILL)")
    #else
    private static let dispatchTrapSignal = (number: SIGTRAP, line: "spaces-test-crash: signal 5 (SIGTRAP)")
    #endif

    @Test("a libdispatch trap prints its signal, reason and stack")
    func dispatchTrapPrintsReasonAndStack() async throws {
        let result = await #expect(
            processExitsWith: .signal(Self.dispatchTrapSignal.number),
            observing: [\.standardErrorContent]
        ) {
            let queue = DispatchQueue(label: "spaces.test.crash-report.queue")
            dispatchPrecondition(condition: .onQueue(queue))
        }
        let stderr = String(decoding: try #require(result).standardErrorContent, as: UTF8.self)
        #expect(stderr.contains(Self.dispatchTrapSignal.line))
        #expect(stderr.contains("BUG IN CLIENT OF LIBDISPATCH"))
        #expect(stderr.contains("spaces.test.crash-report.queue"))
        #expect(stderr.contains("dispatch_assert_queue"))
    }
}
