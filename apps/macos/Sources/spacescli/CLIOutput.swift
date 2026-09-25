import Foundation

struct CLIOutput {
    func emit(_ text: @autoclosure () -> String) { print(text()) }

    func emitLines(_ text: @autoclosure () -> [String]) { for line in text() { print(line) } }

    /// Writes one line to standard error, for a notice that must stay out of a command's stdout payload.
    func emitError(_ text: @autoclosure () -> String) { FileHandle.standardError.write(Data((text() + "\n").utf8)) }

    /// Pretty-printed, key-sorted JSON for `--json` output. Used by machine-readable orchestration
    /// commands so their shape is stable across runs.
    func emitJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
