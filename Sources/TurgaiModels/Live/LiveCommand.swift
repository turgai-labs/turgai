import Mosaic

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// What a client sends over its live connection.
public enum LiveCommand: Codable, Equatable, Sendable {
    /// The conversation `conversationID` of the space `spaceID` the connection shows from now on,
    /// instead of the one before: its history and live turns come, and messages and answers go to
    /// it.
    case open(spaceID: SpaceID, conversationID: ConversationID)
    case message(SendMessageRequest)
    /// An admin's answer to an access request.
    case answer(id: UUID, answer: AccessAnswer)
    /// Something asked, answered by a reply carrying `ref`.
    case push(ref: PushRef, ask: LiveAsk)

    private enum Kind: String, Codable {
        case open
        case message
        case answer
        case push
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, text, to, answer, conversationID
        case ref, ask, topic, remembering, space, chat, name, change, path, version
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .open:
            self = .open(
                spaceID: try values.decode(SpaceID.self, forKey: .space),
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID))
        case .message:
            self = .message(
                SendMessageRequest(
                    id: try values.decode(MessageID.self, forKey: .id),
                    text: try values.decode(String.self, forKey: .text),
                    to: try values.decodeIfPresent([ParticipantRef].self, forKey: .to) ?? []
                ))
        case .answer:
            self = .answer(
                id: try values.decode(UUID.self, forKey: .id),
                answer: try values.decode(AccessAnswer.self, forKey: .answer)
            )
        case .push:
            self = .push(ref: try values.decode(PushRef.self, forKey: .ref), ask: try Self.ask(in: values))
        }
    }

    /// What the push `values` hold asks.
    private static func ask(in values: KeyedDecodingContainer<CodingKeys>) throws -> LiveAsk {
        switch try values.decode(LiveAsk.Name.self, forKey: .ask) {
        case .join: .join(try Self.topic(in: values))
        case .leave: .leave(try Self.topic(in: values))
        case .memory: .memory
        case .forgetMemory: .forgetMemory
        case .setRemembering:
            .setRemembering(try values.decode(MemorySummary.Remembering.self, forKey: .remembering))
        case .archiveSpace: .archiveSpace(try values.decode(SpaceID.self, forKey: .space))
        case .unarchiveSpace: .unarchiveSpace(try values.decode(SpaceID.self, forKey: .space))
        case .leaveConversation:
            .leaveConversation(
                try values.decode(ConversationID.self, forKey: .conversationID),
                of: try values.decode(SpaceID.self, forKey: .space))
        case .deleteConversation:
            .deleteConversation(
                try values.decode(ConversationID.self, forKey: .conversationID),
                of: try values.decode(SpaceID.self, forKey: .space))
        case .stopConversation:
            .stopConversation(
                try values.decode(ConversationID.self, forKey: .conversationID),
                of: try values.decode(SpaceID.self, forKey: .space))
        case .changeSchedule:
            .changeSchedule(
                in: try values.decode(TaskListing.Chat.self, forKey: .chat),
                of: try values.decode(SpaceID.self, forKey: .space),
                named: try values.decode(String.self, forKey: .name),
                try values.decode(ScheduleChange.self, forKey: .change))
        case .cancelReminder:
            .cancelReminder(
                in: try values.decode(TaskListing.Chat.self, forKey: .chat),
                of: try values.decode(SpaceID.self, forKey: .space),
                named: try values.decode(String.self, forKey: .name))
        case .pressPage:
            .pressPage(
                space: try values.decode(SpaceID.self, forKey: .space),
                page: MadeObjectID(rawValue: try values.decode(String.self, forKey: .name)),
                path: try values.decode(PiecePath.self, forKey: .path),
                version: try values.decode(Int.self, forKey: .version))
        }
    }

    /// The topic `values` name: a space's tasks with the space they name too.
    private static func topic(in values: KeyedDecodingContainer<CodingKeys>) throws -> LiveTopic {
        switch try values.decode(LiveTopic.Name.self, forKey: .topic) {
        case .spaces: .spaces
        case .conversations: .conversations
        case .memory: .memory
        case .tasks: .tasks(space: try values.decode(SpaceID.self, forKey: .space))
        case .objects: .objects(space: try values.decode(SpaceID.self, forKey: .space))
        case .pages: .pages(space: try values.decode(SpaceID.self, forKey: .space))
        case .page:
            .page(
                space: try values.decode(SpaceID.self, forKey: .space),
                page: MadeObjectID(rawValue: try values.decode(String.self, forKey: .name)))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .open(let spaceID, let conversationID):
            try values.encode(Kind.open, forKey: .type)
            try values.encode(spaceID, forKey: .space)
            try values.encode(conversationID, forKey: .conversationID)
        case .message(let request):
            try values.encode(Kind.message, forKey: .type)
            try values.encode(request.id, forKey: .id)
            try values.encode(request.text, forKey: .text)
            try values.encode(request.to, forKey: .to)
        case .answer(let id, let answer):
            try values.encode(Kind.answer, forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(answer, forKey: .answer)
        case .push(let ref, let ask):
            try values.encode(Kind.push, forKey: .type)
            try values.encode(ref, forKey: .ref)
            try values.encode(ask.name, forKey: .ask)
            switch ask {
            case .join(let topic), .leave(let topic):
                try values.encode(topic.name, forKey: .topic)
                switch topic {
                case .tasks(let space), .objects(let space), .pages(let space):
                    try values.encode(space, forKey: .space)
                case .page(let space, let page):
                    try values.encode(space, forKey: .space)
                    try values.encode(page.rawValue, forKey: .name)
                case .spaces, .conversations, .memory: break
                }
            case .setRemembering(let remembering): try values.encode(remembering, forKey: .remembering)
            case .archiveSpace(let space), .unarchiveSpace(let space):
                try values.encode(space, forKey: .space)
            case .leaveConversation(let conversation, let space), .deleteConversation(let conversation, let space),
                .stopConversation(let conversation, let space):
                try values.encode(conversation, forKey: .conversationID)
                try values.encode(space, forKey: .space)
            case .changeSchedule(let chat, let space, let name, let change):
                try values.encode(chat, forKey: .chat)
                try values.encode(space, forKey: .space)
                try values.encode(name, forKey: .name)
                try values.encode(change, forKey: .change)
            case .cancelReminder(let chat, let space, let name):
                try values.encode(chat, forKey: .chat)
                try values.encode(space, forKey: .space)
                try values.encode(name, forKey: .name)
            case .pressPage(let space, let page, let path, let version):
                try values.encode(space, forKey: .space)
                try values.encode(page.rawValue, forKey: .name)
                try values.encode(path, forKey: .path)
                try values.encode(version, forKey: .version)
            case .memory, .forgetMemory: break
            }
        }
    }
}
