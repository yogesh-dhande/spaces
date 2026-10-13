import Foundation
import XCTest

@testable import spacesterminalcore

final class ProcessResourceSamplerTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    /// A sampler over scripted readings, so CPU math is checked without real processes.
    private func makeSampler(_ readings: Box) -> ProcessResourceSampler {
        ProcessResourceSampler(reader: { readings.values[$0] })
    }

    private final class Box: @unchecked Sendable { var values: [pid_t: ProcessResourceReading] = [:] }

    func testFirstSampleOnlyPrimesTheBaseline() {
        let box = Box()
        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 5 * second, memoryBytes: 100)
        var sampler = makeSampler(box)
        XCTAssertNil(sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 100 * second))
    }

    func testCPUPercentIsTheShareOfOneCoreOverTheInterval() throws {
        let box = Box()
        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 5 * second, memoryBytes: 100)
        var sampler = makeSampler(box)
        _ = sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 100 * second)

        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 6 * second, memoryBytes: 150)
        var usage = try XCTUnwrap(sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 102 * second)?["a"])
        XCTAssertEqual(usage.cpuPercent, 50, accuracy: 0.001)
        XCTAssertEqual(usage.memoryBytes, 150)

        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 14 * second, memoryBytes: 150)
        usage = try XCTUnwrap(sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 104 * second)?["a"])
        XCTAssertEqual(usage.cpuPercent, 400, accuracy: 0.001, "a group using four cores reads 400")
    }

    func testGroupSumsItsProcessesAndSkipsUnreadableOnes() throws {
        let box = Box()
        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 0, memoryBytes: 100)
        box.values[11] = ProcessResourceReading(cpuTimeNanoseconds: 0, memoryBytes: 200)
        var sampler = makeSampler(box)
        _ = sampler.sample(groups: ["a": [10, 11, 12]], uptimeNanoseconds: 10 * second)

        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: second, memoryBytes: 100)
        box.values[11] = ProcessResourceReading(cpuTimeNanoseconds: second, memoryBytes: 200)
        let usage = try XCTUnwrap(sampler.sample(groups: ["a": [10, 11, 12]], uptimeNanoseconds: 12 * second)?["a"])
        XCTAssertEqual(usage.cpuPercent, 100, accuracy: 0.001)
        XCTAssertEqual(usage.memoryBytes, 300)
        XCTAssertEqual(usage.processCount, 2, "pid 12 has no reading and is not counted")
    }

    func testProcessStartedAfterTheBaselineCountsItsWholeCPUTime() throws {
        let box = Box()
        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 0, memoryBytes: 1)
        var sampler = makeSampler(box)
        _ = sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 10 * second)

        box.values[11] = ProcessResourceReading(cpuTimeNanoseconds: second, memoryBytes: 1)
        let usage = try XCTUnwrap(sampler.sample(groups: ["a": [10, 11]], uptimeNanoseconds: 12 * second)?["a"])
        XCTAssertEqual(usage.cpuPercent, 50, accuracy: 0.001)
    }

    func testPidThatLeavesAndReturnsIsTreatedAsNewRatherThanDiffedAgainstStaleState() throws {
        let box = Box()
        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: 9 * second, memoryBytes: 1)
        var sampler = makeSampler(box)
        _ = sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 10 * second)

        box.values[10] = nil
        _ = sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 12 * second)

        box.values[10] = ProcessResourceReading(cpuTimeNanoseconds: second, memoryBytes: 1)
        let usage = try XCTUnwrap(sampler.sample(groups: ["a": [10]], uptimeNanoseconds: 14 * second)?["a"])
        XCTAssertEqual(usage.cpuPercent, 50, accuracy: 0.001)
    }
}

final class ProcessResourceReaderTests: XCTestCase {
    func testReadsTheCurrentProcess() throws {
        let reading = try XCTUnwrap(ProcessResourceReader.read(processID: getpid()))
        XCTAssertGreaterThan(reading.memoryBytes, 0)
        XCTAssertGreaterThan(reading.cpuTimeNanoseconds, 0)
    }

    func testReturnsNilForAProcessThatDoesNotExist() {
        XCTAssertNil(ProcessResourceReader.read(processID: 0x7FFF_FFF0))
    }

    func testBusyChildReportsCPUBetweenSamples() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "while :; do :; done"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        var sampler = ProcessResourceSampler()
        let group = ["child": [child.processIdentifier]]
        XCTAssertNil(sampler.sample(groups: group, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds))
        Thread.sleep(forTimeInterval: 0.5)
        let usage = try XCTUnwrap(sampler.sample(groups: group, uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)?["child"])
        XCTAssertGreaterThan(usage.cpuPercent, 0)
        XCTAssertGreaterThan(usage.memoryBytes, 0)
        XCTAssertEqual(usage.processCount, 1)
    }
}

final class ProcessTreeTests: XCTestCase {
    func testListsRootFirstThenDescendants() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sleep 30 & wait"]
        try parent.run()
        defer {
            for pid in ProcessTree.processIDs(rootProcessID: parent.processIdentifier).reversed() { kill(pid, SIGKILL) }
            parent.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(3)
        var tree = ProcessTree.processIDs(rootProcessID: parent.processIdentifier)
        while tree.count < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            tree = ProcessTree.processIDs(rootProcessID: parent.processIdentifier)
        }
        XCTAssertEqual(tree.first, parent.processIdentifier)
        XCTAssertEqual(tree.count, 2, "the shell and its background sleep")
    }

    func testExcludedSubtreeIsLeftOutWithItsDescendants() throws {
        // Two children of the shell: a subshell holding a sleep (excluded, with that sleep), and a plain
        // sleep that stays.
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "(sleep 31; true) & sleep 32 & wait"]
        try parent.run()
        defer {
            for pid in ProcessTree.processIDs(rootProcessID: parent.processIdentifier).reversed() { kill(pid, SIGKILL) }
            parent.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(3)
        var full = ProcessTree.processIDs(rootProcessID: parent.processIdentifier)
        while full.count < 4, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            full = ProcessTree.processIDs(rootProcessID: parent.processIdentifier)
        }
        XCTAssertEqual(full.count, 4, "the shell, the subshell, the subshell's sleep, and the plain sleep")

        let subshell = try XCTUnwrap(
            full.dropFirst().first { pid in ProcessTree.processIDs(rootProcessID: pid).count == 2 },
            "the only child that has a child of its own")
        let remaining = ProcessTree.processIDs(rootProcessID: parent.processIdentifier, excludingSubtreesWhere: { $0 == subshell })
        XCTAssertEqual(remaining.count, 2, "the shell and its plain sleep")
        XCTAssertEqual(remaining.first, parent.processIdentifier)
        XCTAssertFalse(remaining.contains(subshell))
    }

    func testProcessWithoutChildrenIsItsOwnTree() {
        XCTAssertEqual(ProcessTree.processIDs(rootProcessID: 0x7FFF_FFF0), [0x7FFF_FFF0])
    }
}
