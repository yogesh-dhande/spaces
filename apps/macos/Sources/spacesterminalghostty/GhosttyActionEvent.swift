import Foundation
import GhosttyKit

public enum GhosttyActionEvent: Sendable, Equatable {
    case setTitle(String)
    case setWorkingDirectory(String)
}

enum GhosttyActionEventParser {
    static func parse(_ action: ghostty_action_s) -> GhosttyActionEvent? {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            guard let title = action.action.set_title.title else { return nil }
            return .setTitle(String(cString: title))
        case GHOSTTY_ACTION_PWD:
            guard let pwd = action.action.pwd.pwd else { return nil }
            return .setWorkingDirectory(String(cString: pwd))
        default: return nil
        }
    }
}
