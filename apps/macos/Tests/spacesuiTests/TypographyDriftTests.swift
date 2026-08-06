import Foundation
import Testing
import spacesterminalcore

/// Guards the chrome type scale. Chrome text is sized by role (``Typography``), never by a font
/// literal at the call site, so a stray `systemFont(ofSize:)` in a UI module is drift back to the
/// per-site sizing the scale replaced.
@Suite struct TypographyDriftTests {
    @Test func everyRoleSitsOnTheScale() {
        for role in TypographyRole.allCases {
            #expect(
                TypographyRole.scale.contains(role.spec.points),
                "\(role) is \(role.spec.points) pt, which is off the scale \(TypographyRole.scale). Snap the role to the scale rather than widening it."
            )
        }
    }

    @Test func chromeModulesUseTypographyTokensInsteadOfFontLiterals() throws {
        let pattern = try NSRegularExpression(pattern: #"(monospaced)?[sS]ystemFont\(ofSize: [0-9]"#)
        var offenders: [String] = []

        for module in Self.chromeModules {
            let root = Self.sourcesURL.appendingPathComponent(module)
            let files = try Self.swiftFiles(under: root)
            // A mislocated source root would make the scan vacuously pass.
            #expect(!files.isEmpty, "No Swift sources found under \(root.path)")
            for file in files {
                let relativePath = "apps/macos/Sources/\(module)/\(file.path.replacingOccurrences(of: root.path + "/", with: ""))"
                for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                    guard pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                    offenders.append("\(relativePath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Chrome text must use a Typography role, not a font literal:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The UI modules whose text is chrome. They hold terminal *content* sizing too, and it is just as
    /// literal-free: content follows the user's `TerminalTextSize`, so a font literal anywhere in these
    /// modules is drift either way.
    private static let chromeModules = ["spacesui", "spacesterminalui", "spacesterminalghostty"]

    private static var sourcesURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // spacesuiTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
            .appendingPathComponent("Sources")
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
