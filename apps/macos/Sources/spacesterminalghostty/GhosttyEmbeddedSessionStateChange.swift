import Foundation

struct GhosttyEmbeddedSessionStateChange: Sendable, Equatable {
    struct Flags: OptionSet, Sendable, Equatable {
        let rawValue: UInt32

        static let screen = Self(rawValue: 1 << 0)
        static let title = Self(rawValue: 1 << 1)
        static let workingDirectory = Self(rawValue: 1 << 2)
        static let foregroundProcess = Self(rawValue: 1 << 3)
        static let size = Self(rawValue: 1 << 4)

        static let metadata: Self = [.title, .workingDirectory]
        static let runtimeState: Self = [.foregroundProcess, .size]
        static let allKnown: Self = [.screen, .title, .workingDirectory, .foregroundProcess, .size]
    }

    let flags: Flags
    let revision: UInt64
    let title: String?
    let workingDirectory: String?
}
