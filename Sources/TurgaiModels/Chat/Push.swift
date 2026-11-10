#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// A push's id, which its reply carries back.
public struct PushRef: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// What a connection can hear about besides the conversation it shows: once it joins one, it's
/// told as it changes, until it leaves.
public enum ChatTopic: Hashable, Sendable {
    /// What's remembered about the person, and whether they're remembered.
    case memory
    /// The tasks of the space with this id that the person may change: what they are as it's
    /// joined, then each change.
    case tasks(space: SpaceID)

    /// What it is, as the socket names it.
    enum Name: String, Codable {
        case memory
        case tasks
    }

    var name: Name {
        switch self {
        case .memory: .memory
        case .tasks: .tasks
        }
    }
}

/// What a connection asks, each answered by a reply.
public enum ChatAsk: Equatable, Sendable {
    /// Told about `topic` from now on.
    case join(ChatTopic)
    /// No longer told about `topic`.
    case leave(ChatTopic)
    /// What's remembered about the person, and whether they're remembered.
    case memory
    /// Everything remembered about them, forgotten; their conversations stay.
    case forgetMemory
    /// What they say remembered from now on, or not.
    case setRemembering(MemorySummary.Remembering)
    /// The space with this id archived, by one of its admins.
    case archiveSpace(SpaceID)
    /// The space with this id in use again, by one of its admins.
    case unarchiveSpace(SpaceID)
    /// The conversation off the asker's list: they no longer read it, and the rest stay in it.
    case leaveConversation(ConversationID)
    /// The conversation deleted for everyone: by the only person in it, or an admin of its space.
    case deleteConversation(ConversationID)
    /// The chat's schedule with this name changed, by whoever made it or an admin of its space.
    case changeSchedule(in: TaskListing.Chat, named: String, ScheduleChange)
    /// The chat's reminder with this name cancelled, by whoever made it or an admin of its space.
    case cancelReminder(in: TaskListing.Chat, named: String)
}

/// The answer to a push.
public enum ChatReply: Equatable, Sendable {
    /// Done.
    case ok
    /// What's remembered about the person.
    case memory(MemorySummary)
    /// It couldn't be done, and why.
    case failed(ChatError)
}

extension ChatAsk {
    /// What it asks, as the socket names it.
    enum Name: String, Codable {
        case join
        case leave
        case memory
        case forgetMemory = "memory.forget"
        case setRemembering = "memory.remembering"
        case archiveSpace = "space.archive"
        case unarchiveSpace = "space.unarchive"
        case leaveConversation = "conversation.leave"
        case deleteConversation = "conversation.delete"
        case changeSchedule = "schedule.change"
        case cancelReminder = "reminder.cancel"
    }

    var name: Name {
        switch self {
        case .join: .join
        case .leave: .leave
        case .memory: .memory
        case .forgetMemory: .forgetMemory
        case .setRemembering: .setRemembering
        case .archiveSpace: .archiveSpace
        case .unarchiveSpace: .unarchiveSpace
        case .leaveConversation: .leaveConversation
        case .deleteConversation: .deleteConversation
        case .changeSchedule: .changeSchedule
        case .cancelReminder: .cancelReminder
        }
    }
}

extension ChatReply {
    /// How it went, as the socket says it.
    enum Status: String, Codable {
        case ok
        case failed
    }
}
