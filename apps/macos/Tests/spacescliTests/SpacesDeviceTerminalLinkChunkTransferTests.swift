import XCTest

@testable import spacesdevicecore

final class SpacesDeviceTerminalLinkChunkTransferTests: XCTestCase {
    /// Call counter usable from a `@Sendable` chunk reader. The download loop awaits each chunk
    /// before requesting the next, so reads never run concurrently and unsynchronized mutation is safe.
    private final class SequentialCallCounter: @unchecked Sendable {
        private(set) var value = 0
        @discardableResult func increment() -> Int {
            value += 1
            return value
        }
    }

    private func makeDestinationURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("chunk-transfer-test-\(UUID().uuidString)")
    }

    /// A fake `readChunk` that splits `data` into fixed-size chunks of `serverChunkSize`, ignoring the
    /// caller's requested limit — the way a real server might enforce its own chunk size — so tests can
    /// exercise multi-chunk assembly with small payloads instead of needing to exceed
    /// `SpacesDeviceTerminalLinkResolver.defaultChunkLimit`.
    private func makeChunkReader(data: Data, serverChunkSize: Int, linkID: String = "link-1") -> SpacesDeviceTerminalLinkChunkTransfer.ChunkReader {
        { offset, _ in
            let start = Int(offset)
            let end = min(start + serverChunkSize, data.count)
            let slice = data[start..<end]
            return SpacesDeviceTerminalLinkChunk(
                linkID: linkID, offset: offset, byteCount: slice.count, isFinal: end >= data.count, base64Data: Data(slice).base64EncodedString())
        }
    }

    func testMultiChunkAssemblyReproducesExactBytes() async throws {
        let data = Data((0..<25_000).map { UInt8($0 % 256) })
        let destinationURL = makeDestinationURL()
        defer { try? FileManager.default.removeItem(at: destinationURL) }

        let written = try await SpacesDeviceTerminalLinkChunkTransfer.download(
            linkID: "link-1", expectedByteCount: Int64(data.count), to: destinationURL, readChunk: makeChunkReader(data: data, serverChunkSize: 4096))

        XCTAssertEqual(written, Int64(data.count))
        XCTAssertEqual(try Data(contentsOf: destinationURL), data)
    }

    func testOffsetMismatchFromMisbehavingServerThrowsAndRemovesPartialFile() async throws {
        let destinationURL = makeDestinationURL()
        let callCounter = SequentialCallCounter()

        do {
            _ = try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: 20, to: destinationURL) { offset, _ in
                let call = callCounter.increment()
                let payload = Data(repeating: 0x41, count: 10)
                // The second chunk reports an offset one past where it was requested.
                let reportedOffset = call == 2 ? offset + 1 : offset
                return SpacesDeviceTerminalLinkChunk(
                    linkID: "link-1", offset: reportedOffset, byteCount: payload.count, isFinal: false, base64Data: payload.base64EncodedString())
            }
            XCTFail("Expected an offset mismatch error")
        } catch SpacesDeviceTerminalLinkChunkTransferError.unexpectedChunkOffset(let linkID, let requestedOffset, let receivedOffset) {
            XCTAssertEqual(linkID, "link-1")
            XCTAssertEqual(requestedOffset, 10)
            XCTAssertEqual(receivedOffset, 11)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testWrongLinkIDThrowsAndRemovesPartialFile() async throws {
        let destinationURL = makeDestinationURL()
        let payload = Data(repeating: 0x41, count: 10)

        do {
            _ = try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: nil, to: destinationURL) { offset, _ in
                SpacesDeviceTerminalLinkChunk(
                    linkID: "stale-link", offset: offset, byteCount: payload.count, isFinal: true, base64Data: payload.base64EncodedString())
            }
            XCTFail("Expected a wrong link ID error")
        } catch SpacesDeviceTerminalLinkChunkTransferError.unexpectedChunkLinkID(let requestedLinkID, let receivedLinkID) {
            XCTAssertEqual(requestedLinkID, "link-1")
            XCTAssertEqual(receivedLinkID, "stale-link")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testByteCountMismatchThrowsAndRemovesPartialFile() async throws {
        let destinationURL = makeDestinationURL()

        do {
            _ = try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: nil, to: destinationURL) { offset, _ in
                let payload = Data(repeating: 0x42, count: 8)
                return SpacesDeviceTerminalLinkChunk(
                    linkID: "link-1", offset: offset, byteCount: payload.count + 1, isFinal: true, base64Data: payload.base64EncodedString())
            }
            XCTFail("Expected a byte count mismatch error")
        } catch SpacesDeviceTerminalLinkChunkTransferError.chunkByteCountMismatch(let linkID, let reportedByteCount, let decodedByteCount) {
            XCTAssertEqual(linkID, "link-1")
            XCTAssertEqual(reportedByteCount, 9)
            XCTAssertEqual(decodedByteCount, 8)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testInvalidBase64ThrowsAndRemovesPartialFile() async throws {
        let destinationURL = makeDestinationURL()

        do {
            _ = try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: nil, to: destinationURL) { offset, _ in
                SpacesDeviceTerminalLinkChunk(linkID: "link-1", offset: offset, byteCount: 4, isFinal: true, base64Data: "not valid base64!!")
            }
            XCTFail("Expected an invalid chunk data error")
        } catch SpacesDeviceTerminalLinkChunkTransferError.invalidChunkData(let linkID) { XCTAssertEqual(linkID, "link-1") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testServerThatNeverSignalsFinalBeyondExpectedSizeThrowsWithoutLooping() async throws {
        let destinationURL = makeDestinationURL()
        let expectedByteCount: Int64 = 100
        let callCounter = SequentialCallCounter()

        do {
            _ = try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: expectedByteCount, to: destinationURL) {
                offset, _ in
                callCounter.increment()
                let payload = Data(repeating: 0x43, count: 50)
                // Never reports isFinal, so only the expected-byte-count guard can stop the loop.
                return SpacesDeviceTerminalLinkChunk(
                    linkID: "link-1", offset: offset, byteCount: payload.count, isFinal: false, base64Data: payload.base64EncodedString())
            }
            XCTFail("Expected a transfer-exceeded-expected-byte-count error")
        } catch SpacesDeviceTerminalLinkChunkTransferError.transferExceededExpectedByteCount(let linkID, let byteCount) {
            XCTAssertEqual(linkID, "link-1")
            XCTAssertEqual(byteCount, expectedByteCount)
        }

        XCTAssertEqual(callCounter.value, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testNonFinalEmptyChunkThrowsWithoutLooping() async throws {
        let destinationURL = makeDestinationURL()
        let callCounter = SequentialCallCounter()

        do {
            _ = try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: nil, to: destinationURL) { offset, _ in
                callCounter.increment()
                return SpacesDeviceTerminalLinkChunk(
                    linkID: "link-1", offset: offset, byteCount: 0, isFinal: false, base64Data: Data().base64EncodedString())
            }
            XCTFail("Expected an empty non-final chunk error")
        } catch SpacesDeviceTerminalLinkChunkTransferError.emptyNonFinalChunk(let linkID, let offset) {
            XCTAssertEqual(linkID, "link-1")
            XCTAssertEqual(offset, 0)
        }

        XCTAssertEqual(callCounter.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    func testCancellationMidDownloadThrowsCancellationErrorAndRemovesPartialFile() async throws {
        let destinationURL = makeDestinationURL()

        let task = Task {
            try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: "link-1", expectedByteCount: nil, to: destinationURL) { offset, _ in
                // Cancels the task currently running the download loop from inside its own chunk fetch, so
                // the helper's post-fetch `Task.checkCancellation()` deterministically observes it on the
                // very first iteration without racing an external `Task.cancel()` call against the loop.
                withUnsafeCurrentTask { $0?.cancel() }
                let payload = Data(repeating: 0x44, count: 4)
                return SpacesDeviceTerminalLinkChunk(
                    linkID: "link-1", offset: offset, byteCount: payload.count, isFinal: false, base64Data: payload.base64EncodedString())
            }
        }

        do {
            _ = try await task.value
            XCTFail("Expected a CancellationError")
        } catch is CancellationError {} catch { XCTFail("Expected a CancellationError, got \(error)") }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
    }
}
