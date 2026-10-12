import Foundation

/// A wire array decoded element by element, keeping the elements this build understands and stepping
/// over the ones it does not.
///
/// A list typed by a closed enum (`CodingAgent`, `TerminalDetectedAgentKind`) would otherwise fail
/// whole when a newer peer has learned a raw value this build has not, taking down the message that
/// carries it (a status handshake, a Coding Agents list). Dropping the unreadable element costs nothing
/// the reader could have used: a row it cannot describe is one it must not show. There is deliberately
/// no "unknown" enum case to catch it, because every consumer would then have to handle a value it can
/// do nothing with.
public struct SkippingUnreadableList<Element: Decodable>: Decodable {
    public let elements: [Element]

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            let position = container.currentIndex
            if let element = try? container.decode(Element.self) { decoded.append(element) }
            // A failed decode may or may not have moved the cursor, depending on the decoder, and
            // `SkippedElement` reads nothing and so consumes whatever is there. Stepping only when the
            // cursor has not moved steps over each unreadable element exactly once, without swallowing
            // the next.
            if container.currentIndex == position { _ = try? container.decode(SkippedElement.self) }
        }
        elements = decoded
    }

    private struct SkippedElement: Decodable { init(from decoder: any Decoder) throws {} }
}

extension KeyedDecodingContainer {
    /// The array under `key` with unreadable elements dropped, or empty when the key is absent.
    public func decodeSkippingUnreadable<Element: Decodable>(_ type: Element.Type, forKey key: Key) throws -> [Element] {
        try decodeIfPresent(SkippingUnreadableList<Element>.self, forKey: key)?.elements ?? []
    }
}
