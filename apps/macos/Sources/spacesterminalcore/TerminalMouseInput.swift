import Foundation

public enum TerminalMouseInput {
    public static func sgrSequence(
        action: TerminalMouseAction, button: TerminalMouseButton, column: Int, row: Int, shift: Bool = false, option: Bool = false,
        control: Bool = false
    ) -> String {
        let encodedButton = sgrButtonCode(action: action, button: button, shift: shift, option: option, control: control)
        let terminator = sgrTerminator(for: action)
        return "\u{001B}[<\(encodedButton);\(max(column, 1));\(max(row, 1))\(terminator)"
    }

    private static func sgrButtonCode(action: TerminalMouseAction, button: TerminalMouseButton, shift: Bool, option: Bool, control: Bool) -> Int {
        var code: Int
        switch action {
        case .press, .release, .move:
            switch button {
            case .left: code = 0
            case .middle: code = 1
            case .right: code = 2
            case .none: code = 3
            }
            if action == .move { code += 32 }
        case .scrollUp: code = 64
        case .scrollDown: code = 65
        }
        if shift { code += 4 }
        if option { code += 8 }
        if control { code += 16 }
        return code
    }

    private static func sgrTerminator(for action: TerminalMouseAction) -> String {
        switch action {
        case .release: "m"
        default: "M"
        }
    }
}
