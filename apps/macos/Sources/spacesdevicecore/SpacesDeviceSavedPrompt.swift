import Foundation

/// A prompt the user saved on one device. Timestamps are fixed-width UTC strings
/// (`TerminalSessionTimestamp.fractionalString`), so comparing them as text orders them in time.
public struct SpacesDeviceSavedPrompt: Codable, Sendable, Equatable, Identifiable {
    /// The longest prompt text a device stores, in UTF-8 bytes. The daemon rejects a longer text so one
    /// list fetch stays bounded; clients show `tooLongMessage` rather than composing their own.
    public static let maximumTextBytes = 102_400
    public static let tooLongMessage = "Prompts can be up to 100 KB."

    public let id: String
    public let title: String
    public let text: String
    public let createdAt: String
    public let updatedAt: String
    /// When the prompt was last copied, or created when it never was. Orders the library.
    public let lastUsedAt: String

    public init(id: String, title: String, text: String, createdAt: String, updatedAt: String, lastUsedAt: String) {
        self.id = id
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// A device's whole prompt library, ordered most recently used first, with the revision it was read at.
/// The revision only goes up, so a client can drop a response older than one it already applied.
public struct SpacesDeviceSavedPromptsResult: Codable, Sendable, Equatable {
    public let prompts: [SpacesDeviceSavedPrompt]
    public let revision: Int
    /// The id of the prompt a create just added. Set only on a create response; nil on every other response.
    public let createdPromptID: String?

    public init(prompts: [SpacesDeviceSavedPrompt], revision: Int, createdPromptID: String? = nil) {
        self.prompts = prompts
        self.revision = revision
        self.createdPromptID = createdPromptID
    }
}

/// Creates a prompt. Both fields are required:the title must be non-empty once trimmed, and the text must
/// not be blank. The text is stored as typed.
public struct SpacesDeviceSavedPromptFields: Codable, Sendable, Equatable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// Replaces a prompt's title and text. Editing does not change its place in the library.
public struct SpacesDeviceSavedPromptUpdateRequest: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let text: String

    public init(id: String, title: String, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// Names one prompt, to delete it or to record that it was copied.
public struct SpacesDeviceSavedPromptReference: Codable, Sendable, Equatable {
    public let id: String

    public init(id: String) { self.id = id }
}
