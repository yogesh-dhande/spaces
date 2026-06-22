import Foundation

public enum SpacesClientError: LocalizedError, Equatable {
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArgument(let message): message
        }
    }
}
