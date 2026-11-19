import Foundation

/// Cheap test that a line mentions one of a set of `"type":"..."` needles, so a reader can skip decoding the
/// (often very large) lines that carry only tool output. Writers emit compact JSON, so the needles are
/// written without whitespace around the colon.
///
/// Every needle contains `"type":"`. The line is searched once for that anchor, by scanning for its rare
/// letter `y` with `memchr` (vectorized) and checking the neighbours; each anchor hit is then compared
/// against every needle's surroundings. Searching each needle separately with `memmem` made this test the
/// largest cost of reading a transcript, because `"` starts a match at nearly every byte of JSON.
struct JSONLineFilter {
    private struct Needle {
        let lead: [UInt8]  // bytes before the anchor
        let tail: [UInt8]  // bytes after the anchor
    }

    private static let anchor = Array("\"type\":\"".utf8)
    /// Offset of `y` inside the anchor.
    private static let anchorLetter = 2
    private let needles: [Needle]

    init(needles: [String]) {
        self.needles = needles.map { text in
            let bytes = Array(text.utf8)
            guard let start = Self.firstIndex(of: Self.anchor, in: bytes) else {
                preconditionFailure("line filter needle \(text) must contain \"type\":\"")
            }
            return Needle(lead: Array(bytes[..<start]), tail: Array(bytes[(start + Self.anchor.count)...]))
        }
    }

    func matches(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        let count = line.count
        var position = 0
        while position < count {
            guard let found = memchr(base + position, Int32(UInt8(ascii: "y")), count - position) else { return false }
            let letter = base.distance(to: UnsafeRawPointer(found))
            position = letter + 1
            let start = letter - Self.anchorLetter
            guard start >= 0, start + Self.anchor.count <= count, Self.equal(base + start, Self.anchor) else { continue }
            let tailStart = start + Self.anchor.count
            for needle in needles where start >= needle.lead.count && tailStart + needle.tail.count <= count {
                if Self.equal(base + tailStart, needle.tail) && (needle.lead.isEmpty || Self.equal(base + start - needle.lead.count, needle.lead)) {
                    return true
                }
            }
        }
        return false
    }

    private static func equal(_ pointer: UnsafeRawPointer, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { memcmp(pointer, $0.baseAddress!, $0.count) == 0 }
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        return (0...(bytes.count - pattern.count)).first { Array(bytes[$0..<($0 + pattern.count)]) == pattern }
    }
}
