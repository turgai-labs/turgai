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
    /// The objects of the space with this id that the person may read: that they changed, as one
    /// is made, removed, shared or installed.
    case objects(space: SpaceID)
    /// One of the space's pages: that it changed, so what it shows may be other now.
    case page(space: SpaceID, page: MadeObjectID)

    /// What it is, as the socket names it.
    enum Name: String, Codable {
        case memory
        case tasks
        case objects
        case page
    }

    var name: Name {
        switch self {
        case .memory: .memory
        case .tasks: .tasks
        case .objects: .objects
        case .page: .page
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
    /// The conversation of the space off the asker's list: they no longer read it, and the rest
    /// stay in it.
    case leaveConversation(ConversationID, of: SpaceID)
    /// The conversation of the space deleted for everyone: by the only person in it, or someone
    /// the space lets delete anyone's.
    case deleteConversation(ConversationID, of: SpaceID)
    /// The reply the conversation of the space is working on stopped; everything said in it stays.
    case stopConversation(ConversationID, of: SpaceID)
    /// The schedule with this name in the space's chat changed, by whoever made it or someone who
    /// manages the space's tasks.
    case changeSchedule(in: TaskListing.Chat, of: SpaceID, named: String, ScheduleChange)
    /// The reminder with this name in the space's chat cancelled, by whoever made it or someone
    /// who manages the space's tasks.
    case cancelReminder(in: TaskListing.Chat, of: SpaceID, named: String)
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
        case stopConversation = "conversation.stop"
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
        case .stopConversation: .stopConversation
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
