#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A connection of a space: its own among the space's.
public struct ConnectionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    /// The connection `written` names: none when it names none.
    public init?(_ written: String) {
        guard let id = UUID(uuidString: written) else { return nil }
        self.rawValue = id
    }

    public var description: String { rawValue.uuidString }
}

/// What a connection is called among its space's: some words, at most 120 letters.
public struct ConnectionLabel: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumLength = 120

    public let rawValue: String

    /// `written`, trimmed: none when it's empty or too long.
    public init?(_ written: String) {
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maximumLength else { return nil }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

/// The platform a connection is on, with what it's set up with there: its account's secret is
/// kept apart, by the connection's id.
public enum ConnectionPlatform: Hashable, Codable, Sendable {
    /// A Telegram bot, reached by its chats.
    case telegram(TelegramAccess)

    /// What the platform is called, as its chats' channels are named.
    public var name: String {
        switch self {
        case .telegram: "telegram"
        }
    }
}

/// Which Telegram chats reach a connection's bot: every chat when none are listed.
public struct TelegramAccess: Hashable, Codable, Sendable {
    public var chatIDs: [Int64]

    public init(chatIDs: [Int64] = []) {
        self.chatIDs = chatIDs
    }

    /// Whether the chat `chatID` reaches it.
    public func lets(_ chatID: Int64) -> Bool {
        chatIDs.isEmpty || chatIDs.contains(chatID)
    }
}

/// A way into a space from a platform: an account there, whose chats are conversations of the
/// space, answered by its main bot, whoever writes in them one of its members. It runs while it's
/// enabled, and only once it's added.
public struct Connection: Hashable, Codable, Sendable, Identifiable {
    public let id: ConnectionID
    public var label: ConnectionLabel
    public var enabled: Bool
    public var platform: ConnectionPlatform

    public init(id: ConnectionID = ConnectionID(), label: ConnectionLabel, enabled: Bool, platform: ConnectionPlatform)
    {
        self.id = id
        self.label = label
        self.enabled = enabled
        self.platform = platform
    }

    /// The channel its chats' conversations are on: its platform's, its own there.
    public var channel: ChannelID {
        ChannelID(provider: platform.name, instanceID: id.description)
    }
}
