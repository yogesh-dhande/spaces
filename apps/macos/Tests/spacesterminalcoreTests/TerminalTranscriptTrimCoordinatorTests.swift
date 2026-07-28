import Foundation
import XCTest

@testable import spacesterminalcore

/// Covers what the off-engine trim split adds on top of the trim content contract
/// (`TerminalTranscriptTrimTests`): a session keeps appending to `output.log` while its own trim stages
/// in the background, so those appends must survive the swap; a session runs at most one trim at a time;
/// and a trim that fails or is abandoned mid-staging must leave the transcript exactly as it was.
///
/// Every test drives the coordinator through `TerminalEngineActor.run` blocks. That is not ceremony — a
/// single `run` block is one engine-actor turn, and the trim's commit needs a turn of its own, so
/// anything done inside one block is guaranteed to happen while the trim is still staging. That is what
/// makes the racing-append and second-trigger cases deterministic instead of timing-dependent.
final class TerminalTranscriptTrimCoordinatorTests: XCTestCase {
    /// Stands in for a session core's transcript ownership: the append handle and end offset the
    /// coordinator reads at commit time, and the handle swap it hands back. Engine-actor isolated exactly
    /// as the real cores' `outputHandle`/`outputByteCount` are.
    @TerminalEngineActor private final class TranscriptOwner {
        var handle: FileHandle?
        var endOffset: UInt64
        private(set) var adoptionCount = 0

        init(handle: FileHandle, endOffset: UInt64) {
            self.handle = handle
            self.endOffset = endOffset
        }

        func append(_ data: Data) throws {
            try handle?.write(contentsOf: data)
            endOffset += UInt64(data.count)
        }

        func adopt(_ newHandle: FileHandle, endOffset newEndOffset: UInt64) {
            try? handle?.close()
            handle = newHandle
            endOffset = newEndOffset
            adoptionCount += 1
        }

        func releaseTranscript() {
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: - Fixtures

    private static let triggerBytes: UInt64 = 4000
    private static let retainedBytes: UInt64 = 2000

    /// A transcript pre-filled past the trigger, plus its owner and coordinator, all wired up.
    private func makeTrimmableTranscript() async throws -> (
        url: URL, owner: TranscriptOwner, coordinator: TerminalTranscriptTrimCoordinator, oldestLine: String, newestLine: String
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        var filler = Data()
        var index = 0
        while filler.count < 6000 {
            filler.append(Data("SEQ \(String(format: "%06d", index))\n".utf8))
            index += 1
        }
        try handle.write(contentsOf: filler)

        let owner = await TerminalEngineActor.run { TranscriptOwner(handle: handle, endOffset: UInt64(filler.count)) }
        let coordinator = await TerminalEngineActor.run {
            TerminalTranscriptTrimCoordinator(
                outputPath: url.path, triggerBytes: Self.triggerBytes, retainedBytes: Self.retainedBytes,
                liveTranscriptEndOffset: { owner.handle == nil ? nil : owner.endOffset }, adoptTrimmedTranscript: { owner.adopt($0, endOffset: $1) })
        }
        addTeardownBlock {
            await TerminalEngineActor.run { owner.releaseTranscript() }
            try? FileManager.default.removeItem(at: directory)
        }
        return (url, owner, coordinator, "SEQ 000000", "SEQ \(String(format: "%06d", index - 1))")
    }

    private func ownerState(_ owner: TranscriptOwner) async -> (adoptionCount: Int, endOffset: UInt64) {
        await TerminalEngineActor.run { (owner.adoptionCount, owner.endOffset) }
    }

    // MARK: - Appends racing an in-flight trim

    /// The whole point of staging off the engine actor: the session keeps writing to `output.log` while
    /// its trim runs. Those bytes are appended past the staged snapshot's end, so the commit must copy
    /// them onto the staged tail before the swap — otherwise the rename would silently drop every byte
    /// the session produced during the trim.
    func testAppendsDuringStagingSurviveTheTrim() async throws {
        let (url, owner, coordinator, oldestLine, newestLine) = try await makeTrimmableTranscript()

        let racingAppend = Data("RACING-APPEND\n".utf8)
        try await TerminalEngineActor.run {
            coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24)
            // Same engine turn as the trigger, so this lands while the trim is staging: the commit that
            // reads the end offset and renames cannot run until this turn ends.
            try owner.append(racingAppend)
        }
        await coordinator.awaitLatestTrim()

        let state = await ownerState(owner)
        XCTAssertEqual(state.adoptionCount, 1, "The trim must commit and hand back a fresh handle.")

        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(state.endOffset), "The adopted end offset must equal the trimmed file's size.")
        XCTAssertEqual(onDisk.suffix(racingAppend.count), racingAppend, "Bytes appended while the trim staged must survive the swap.")
        let text = String(decoding: onDisk, as: UTF8.self)
        XCTAssertTrue(text.contains(newestLine), "The newest pre-trim content must survive the trim.")
        XCTAssertFalse(text.contains(oldestLine), "The trim must still drop the oldest content.")

        // The adopted handle appends at the post-trim end, immediately after the caught-up delta.
        let afterTrim = Data("AFTER-TRIM\n".utf8)
        try await TerminalEngineActor.run { try owner.append(afterTrim) }
        XCTAssertEqual(try Data(contentsOf: url), onDisk + afterTrim)
    }

    // MARK: - Per-session serialization

    /// At most one trim per session may be in flight: a second trigger while the first stages is dropped,
    /// not queued. Both would stage into the same sibling temp file and both would rename it over
    /// `output.log`, so a second concurrent trim would corrupt the transcript. Dropping costs nothing —
    /// the next append past the trigger re-evaluates against a fresh end offset, which is what the second
    /// half of this test asserts: the gate releases once a trim commits.
    func testSecondTriggerDuringAnInFlightTrimIsDroppedAndTheGateReleases() async throws {
        let (url, owner, coordinator, _, _) = try await makeTrimmableTranscript()

        await TerminalEngineActor.run {
            coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24)
            coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24)
        }
        await coordinator.awaitLatestTrim()

        var state = await ownerState(owner)
        XCTAssertEqual(state.adoptionCount, 1, "A trigger fired while a trim is staging must not start a second trim.")
        XCTAssertEqual(try Data(contentsOf: url).count, Int(state.endOffset), "One trim must leave the file and the adopted end offset in agreement.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".trim"), "A committed trim must leave no temp file behind.")

        // Grow past the trigger again: the session must be trimmable once more.
        var moreOutput = Data()
        var index = 0
        while moreOutput.count < 4000 {
            moreOutput.append(Data("MORE \(String(format: "%06d", index))\n".utf8))
            index += 1
        }
        try await TerminalEngineActor.run {
            try owner.append(moreOutput)
            coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24)
        }
        await coordinator.awaitLatestTrim()

        state = await ownerState(owner)
        XCTAssertEqual(state.adoptionCount, 2, "The in-flight gate must release when a trim commits.")
        XCTAssertEqual(try Data(contentsOf: url).count, Int(state.endOffset))
    }

    /// A burst can append more than the trigger/retained gap while a trim stages; the commit then adopts
    /// a file already past the trigger, and — because every trigger during staging was dropped — if the
    /// burst stops there, no later append would re-evaluate. The coordinator re-checks with the adopted
    /// end, so the transcript converges back under the bound instead of staying oversized indefinitely.
    func testOversizedRacingAppendTriggersAFollowUpTrim() async throws {
        let (url, owner, coordinator, _, _) = try await makeTrimmableTranscript()

        var burst = Data()
        var index = 0
        while burst.count < 5000 {
            burst.append(Data("BURST \(String(format: "%06d", index))\n".utf8))
            index += 1
        }
        try await TerminalEngineActor.run {
            coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24)
            try owner.append(burst)
        }
        // The first await returns once the initial trim commits (adopting a still-oversized file); the
        // follow-up it schedules is the latest trim by then, so the second await covers it.
        await coordinator.awaitLatestTrim()
        await coordinator.awaitLatestTrim()

        let state = await ownerState(owner)
        XCTAssertEqual(state.adoptionCount, 2, "An adopted end still past the trigger must start a follow-up trim.")
        XCTAssertLessThanOrEqual(state.endOffset, Self.triggerBytes, "The follow-up trim must bring the transcript back under the trigger.")
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, Int(state.endOffset))
        XCTAssertEqual(onDisk.suffix(20), burst.suffix(20), "The newest burst bytes must survive both trims.")
    }

    // MARK: - Crash safety

    /// A staging failure must leave `output.log` byte-identical and the session's own append handle valid
    /// at the unchanged end — the trim writes only to the sibling temp file until the atomic rename, so
    /// there is nothing half-written to recover from. The failure is forced by pre-creating a DIRECTORY at
    /// the temp path: opening it for writing fails with `EISDIR`, which not even root can bypass, while the
    /// already-open `output.log` append fd is untouched.
    func testStagingFailureLeavesTheTranscriptAndAppendHandleIntact() async throws {
        let (url, owner, coordinator, _, _) = try await makeTrimmableTranscript()
        let before = try Data(contentsOf: url)

        try FileManager.default.createDirectory(atPath: url.path + ".trim", withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: url.path + ".trim") }

        await TerminalEngineActor.run { coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24) }
        await coordinator.awaitLatestTrim()

        let state = await ownerState(owner)
        XCTAssertEqual(state.adoptionCount, 0, "A failed trim must not swap the session's handle.")
        XCTAssertEqual(state.endOffset, UInt64(before.count), "A failed trim must leave the session's end offset unchanged.")
        XCTAssertEqual(try Data(contentsOf: url), before, "A failed trim must leave output.log byte-identical.")

        let appended = Data("AFTER-FAILURE\n".utf8)
        try await TerminalEngineActor.run { try owner.append(appended) }
        XCTAssertEqual(try Data(contentsOf: url), before + appended, "The session's original handle must still append at the original end.")
    }

    /// A session that gives up its transcript while a trim stages — it terminated, or handed `output.log`
    /// to the daemon-handoff writer — abandons the trim rather than renaming a stale file over whatever
    /// owns the path now. The staged temp file must be cleaned up rather than stranded for the orphan
    /// sweep, and the transcript must be byte-identical.
    func testTrimAbandonedWhenTheSessionReleasesItsTranscript() async throws {
        let (url, owner, coordinator, _, _) = try await makeTrimmableTranscript()
        let before = try Data(contentsOf: url)

        await TerminalEngineActor.run {
            coordinator.trimIfNeeded(currentEndOffset: owner.endOffset, columns: 80, rows: 24)
            owner.releaseTranscript()
        }
        await coordinator.awaitLatestTrim()

        let state = await ownerState(owner)
        XCTAssertEqual(state.adoptionCount, 0, "An abandoned trim must not hand a handle back to a session that closed its transcript.")
        XCTAssertEqual(try Data(contentsOf: url), before, "An abandoned trim must leave output.log byte-identical.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".trim"), "An abandoned trim must not strand its temp file.")
    }
}
