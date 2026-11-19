import Foundation

/// Streams a JSONL transcript through an agent's record handler.
enum JSONLTranscriptReader {
    /// Reads `file` and calls `handle` with each decoded record of the lines that mention one of `needles`.
    ///
    /// A plain transcript is read from `offset` and reports the offset just past its last complete line. A
    /// compressed transcript is immutable, so it reports `.complete`; its `offset` is nonzero only when the
    /// plain file it was compressed from was already read that far.
    static func read(
        _ file: AgentSessionFile, from offset: Int64, needles: [String], isCancelled: () -> Bool,
        handle: (JSONObject, inout SessionReadAccumulator) -> Void
    ) throws -> AgentSessionReadResult {
        var accumulator = SessionReadAccumulator()
        let filter = JSONLineFilter(needles: needles)
        let process: (UnsafeRawBufferPointer) -> Void = { line in
            guard filter.matches(line) else { return }
            withAutoreleasePool {
                guard let record = JSONLine.object(line) else { return }
                handle(record, &accumulator)
            }
        }
        if file.kind == .compressedTranscript {
            var source = try ZstdByteChunks(path: file.path, skippingBytes: offset)
            _ = try JSONLineScanner(startOffset: offset, acceptsUnterminatedFinalLine: true).scan(&source, isCancelled: isCancelled, body: process)
            return accumulator.result(nextState: .complete)
        }
        var source = try FileByteChunks(path: file.path, offset: offset)
        let end = try JSONLineScanner(startOffset: offset).scan(&source, isCancelled: isCancelled, body: process)
        return accumulator.result(nextState: .byteOffset(end))
    }
}
