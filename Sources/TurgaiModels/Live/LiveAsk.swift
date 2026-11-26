import Mosaic

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
/// told what it is now, then as it changes, until it leaves.
public enum LiveTopic: Hashable, Sendable {
    /// The spaces the person is in, each as it lists itself for them.
    case spaces
    /// The conversations the person is in, in Turgai's apps.
    case conversations
    /// What's remembered about the person, and whether they're remembered.
    case memory
    /// The tasks of the space with this id that the person may change: what they are as it's
    /// joined, then each change.
    case tasks(space: SpaceID)
    /// The objects of the space with this id that the person may read: what they are as it's
    /// joined, then again each time one is made, removed, shared or installed.
    case objects(space: SpaceID)
    /// The pages of the space with this id that the person may read: what they are as it's joined,
    /// then again each time its objects change.
    case pages(space: SpaceID)
    /// One of the space's pages: what it shows as it's joined, then again each time that changes.
    case page(space: SpaceID, page: MadeObjectID)

    /// What it is, as the socket names it.
    enum Name: String, Codable {
        case spaces
        case conversations
        case memory
        case tasks
        case objects
        case pages
        case page
    }

    var name: Name {
        switch self {
        case .spaces: .spaces
        case .conversations: .conversations
        case .memory: .memory
        case .tasks: .tasks
        case .objects: .objects
        case .pages: .pages
        case .page: .page
        }
    }
}

/// What a connection asks, each answered by a reply.
public enum LiveAsk: Equatable, Sendable {
    /// Told about `topic` from now on.
    case join(LiveTopic)
    /// No longer told about `topic`.
    case leave(LiveTopic)
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
    /// The button at `path` of the page pressed, on the layout it showed as `version`: not taken
    /// once that layout is replaced.
    case pressPage(space: SpaceID, page: MadeObjectID, path: PiecePath, version: Int)
}

/// The answer to a push.
public enum LiveReply: Equatable, Sendable {
    /// Done.
    case ok
    /// A topic joined, with what it is now: the event that tells it, as the topic's later events
    /// tell each change.
    indirect case joined(LiveEvent)
    /// What's remembered about the person.
    case memory(MemorySummary)
    /// It couldn't be done, and why.
    case failed(ChatError)
}

extension LiveReply: CustomStringConvertible {
    /// What it is, in short: what a join answers named by its kind, not written out.
    public var description: String {
        switch self {
        case .ok: "ok"
        case .joined(let now): "joined \(now.type.rawValue)"
        case .memory: "memory"
        case .failed(let error): "failed \(error.code)"
        }
    }
}

extension LiveAsk {
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
        case pressPage = "page.press"
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
        case .pressPage: .pressPage
        }
    }
}

extension LiveReply {
    /// How it went, as the socket says it.
    enum Status: String, Codable {
        case ok
        case failed
    }
}
