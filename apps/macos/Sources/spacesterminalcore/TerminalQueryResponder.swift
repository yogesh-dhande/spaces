import Foundation

struct TerminalQueryResponder {
    private static let supportedPrivateModes: Set<Int> = [25, 47, 1000, 1002, 1003, 1004, 1006, 1007, 1047, 1048, 1049, 2004]
    private static let foregroundResponseST = Data("\u{001B}]10;rgb:dddd/dddd/dddd\u{001B}\\".utf8)
    private static let foregroundResponseBEL = Data("\u{001B}]10;rgb:dddd/dddd/dddd\u{0007}".utf8)
    private static let backgroundResponseST = Data("\u{001B}]11;rgb:1111/1111/1111\u{001B}\\".utf8)
    private static let backgroundResponseBEL = Data("\u{001B}]11;rgb:1111/1111/1111\u{0007}".utf8)
    private static let trailingByteLimit = 128

    private var trailingBytes = [UInt8]()
    private var privateModes = Set<Int>()

    mutating func responses(for output: Data) -> [Data] {
        guard !output.isEmpty else { return [] }
        let combined = trailingBytes + Array(output)
        let prefixCount = trailingBytes.count
        var responses = [Data]()
        var index = 0

        while index < combined.count {
            guard combined[index] == 0x1B else {
                index += 1
                continue
            }

            guard index + 1 < combined.count else { break }
            switch combined[index + 1] {
            case 0x5B:
                guard let parsed = parseCSI(in: combined, startingAt: index) else {
                    trailingBytes = Array(combined.suffix(min(Self.trailingByteLimit, combined.count - index)))
                    return responses
                }
                if parsed.range.upperBound > prefixCount, let response = response(for: parsed.sequence) { responses.append(response) }
                applySideEffects(for: parsed.sequence)
                index = parsed.range.upperBound
            case 0x5D:
                guard let parsed = parseOSC(in: combined, startingAt: index) else {
                    trailingBytes = Array(combined.suffix(min(Self.trailingByteLimit, combined.count - index)))
                    return responses
                }
                if parsed.range.upperBound > prefixCount, let response = response(for: parsed.sequence) { responses.append(response) }
                index = parsed.range.upperBound
            default: index += 1
            }
        }

        trailingBytes = Array(combined.suffix(min(Self.trailingByteLimit, combined.count)))
        return responses
    }

    private mutating func applySideEffects(for sequence: ControlSequence) {
        guard case .csi(let parameters, let marker, _, let finalByte) = sequence else { return }
        guard marker == "?" else { return }
        guard finalByte == "h" || finalByte == "l" else { return }
        let enabled = finalByte == "h"
        for value in parameters.split(separator: ";").compactMap({ Int($0) }) {
            if enabled { privateModes.insert(value) } else { privateModes.remove(value) }
        }
    }

    private func response(for sequence: ControlSequence) -> Data? {
        switch sequence {
        case .csi(let parameters, let marker, let intermediate, let finalByte):
            switch (marker, intermediate, finalByte, parameters) {
            case ("", "", "n", "5"): return Data("\u{001B}[0n".utf8)
            case ("", "", "n", "6"): return Data("\u{001B}[1;1R".utf8)
            case ("", "", "c", ""): return Data("\u{001B}[?62;4;22c".utf8)
            case (">", "", "c", ""): return Data("\u{001B}[>0;10;1c".utf8)
            case ("?", "$", "p", _): return modeReportResponse(for: parameters)
            default: return nil
            }
        case .osc(let sequence): return oscResponse(for: sequence.payload, terminator: sequence.terminator)
        }
    }

    private func modeReportResponse(for parameters: String) -> Data? {
        guard let mode = Int(parameters) else { return nil }
        guard Self.supportedPrivateModes.contains(mode) else { return Data("\u{001B}[?\(mode);0$y".utf8) }
        let status = privateModes.contains(mode) ? 1 : 2
        return Data("\u{001B}[?\(mode);\(status)$y".utf8)
    }

    private func oscResponse(for payload: String, terminator: OSCSequence.Terminator) -> Data? {
        switch payload {
        case "10;?": return terminator == .st ? Self.foregroundResponseST : Self.foregroundResponseBEL
        case "11;?": return terminator == .st ? Self.backgroundResponseST : Self.backgroundResponseBEL
        default:
            guard payload.hasPrefix("4;"), let response = paletteResponse(for: payload, terminator: terminator) else { return nil }
            return response
        }
    }

    private func paletteResponse(for payload: String, terminator: OSCSequence.Terminator) -> Data? {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "4", parts[2] == "?" else { return nil }
        guard let index = Int(parts[1]), let color = paletteColor(index: index) else { return nil }
        let terminatorText = terminator == .st ? "\u{001B}\\" : "\u{0007}"
        return Data("\u{001B}]4;\(index);rgb:\(color)\(terminatorText)".utf8)
    }

    private func paletteColor(index: Int) -> String? {
        guard (0...255).contains(index) else { return nil }
        let rgb: (Int, Int, Int)
        switch index {
        case 0...15:
            let palette: [(Int, Int, Int)] = [
                (0x00, 0x00, 0x00), (0xcd, 0x00, 0x00), (0x00, 0xcd, 0x00), (0xcd, 0xcd, 0x00), (0x00, 0x00, 0xee), (0xcd, 0x00, 0xcd),
                (0x00, 0xcd, 0xcd), (0xe5, 0xe5, 0xe5), (0x7f, 0x7f, 0x7f), (0xff, 0x00, 0x00), (0x00, 0xff, 0x00), (0xff, 0xff, 0x00),
                (0x5c, 0x5c, 0xff), (0xff, 0x00, 0xff), (0x00, 0xff, 0xff), (0xff, 0xff, 0xff),
            ]
            rgb = palette[index]
        case 16...231:
            let value = index - 16
            let steps = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
            rgb = (steps[value / 36], steps[(value / 6) % 6], steps[value % 6])
        default:
            let gray = 8 + (index - 232) * 10
            rgb = (gray, gray, gray)
        }
        return [rgb.0, rgb.1, rgb.2].map(Self.hex16).joined(separator: "/")
    }

    private static func hex16(_ component: Int) -> String { String(format: "%04x", component * 257) }

    private func parseCSI(in bytes: [UInt8], startingAt start: Int) -> ParsedSequence? {
        var index = start + 2
        var marker = ""
        if index < bytes.count, bytes[index] == 0x3F || bytes[index] == 0x3E {
            marker = String(UnicodeScalar(bytes[index]))
            index += 1
        }

        let parameterStart = index
        while index < bytes.count, (0x30...0x3F).contains(bytes[index]) { index += 1 }
        guard index < bytes.count else { return nil }
        let parameters = String(decoding: bytes[parameterStart..<index], as: UTF8.self)

        let intermediateStart = index
        while index < bytes.count, (0x20...0x2F).contains(bytes[index]) { index += 1 }
        guard index < bytes.count else { return nil }
        let intermediate = String(decoding: bytes[intermediateStart..<index], as: UTF8.self)

        let finalByteValue = bytes[index]
        guard (0x40...0x7E).contains(finalByteValue) else { return nil }
        let finalScalar = UnicodeScalar(finalByteValue)
        let finalByte = String(finalScalar)
        return ParsedSequence(
            range: start..<(index + 1), sequence: .csi(parameters: parameters, marker: marker, intermediate: intermediate, finalByte: finalByte))
    }

    private func parseOSC(in bytes: [UInt8], startingAt start: Int) -> ParsedSequence? {
        var index = start + 2
        while index < bytes.count {
            switch bytes[index] {
            case 0x07:
                let payload = String(decoding: bytes[(start + 2)..<index], as: UTF8.self)
                return ParsedSequence(range: start..<(index + 1), sequence: .osc(OSCSequence(payload: payload, terminator: .bel)))
            case 0x1B where index + 1 < bytes.count && bytes[index + 1] == 0x5C:
                let payload = String(decoding: bytes[(start + 2)..<index], as: UTF8.self)
                return ParsedSequence(range: start..<(index + 2), sequence: .osc(OSCSequence(payload: payload, terminator: .st)))
            default: index += 1
            }
        }
        return nil
    }
}

private struct ParsedSequence {
    let range: Range<Int>
    let sequence: ControlSequence
}

private enum ControlSequence {
    case csi(parameters: String, marker: String, intermediate: String, finalByte: String)
    case osc(OSCSequence)
}

private struct OSCSequence {
    enum Terminator {
        case bel
        case st
    }

    let payload: String
    let terminator: Terminator
}
