#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// Transport-neutral values for clients of the Turgai conversation API.
///
/// The API describes bots, conversations, messages, and execution events. It
/// deliberately has no account, role, or authentication model. A deployment
/// authenticates the calling application at its transport boundary.
public struct BotID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ConversationID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct MessageID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let rawValue = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a UUID string."
            )
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}

public struct TurnID: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let rawValue = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a UUID string."
            )
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }
}

public struct Bot: Codable, Equatable, Sendable, Identifiable {
    public let id: BotID
    public let name: String

    public init(id: BotID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Conversation: Codable, Equatable, Sendable, Identifiable {
    public let id: ConversationID
    /// The bot that answers in it: none once its bot has left, until another is brought in.
    public let botID: BotID?
    /// Its title, or else the first line of the first thing said in it: none until either.
    public let title: String?
    /// The space it's in.
    public let spaceID: SpaceID
    /// How many people are in it.
    public let people: Int

    public init(id: ConversationID, botID: BotID?, title: String? = nil, spaceID: SpaceID, people: Int) {
        self.id = id
        self.botID = botID
        self.title = title
        self.spaceID = spaceID
        self.people = people
    }
}

/// Someone in a conversation, as the API names them: a person, by their id, or an agent, by its
/// bot id; with what they're called.
public struct ParticipantSummary: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case person
        case agent
    }

    public let kind: Kind
    public let id: String
    public let name: String

    public init(kind: Kind, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }
}

/// Someone in a conversation, or to be: a person, by their id, or an agent, by its bot id. What adding
/// one takes, and who a message is said to.
public struct ParticipantRef: Codable, Hashable, Sendable {
    public let kind: ParticipantSummary.Kind
    public let id: String

    public init(kind: ParticipantSummary.Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// What to call a conversation.
public struct TitleConversationRequest: Codable, Equatable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct Message: Codable, Equatable, Sendable, Identifiable {
    public let id: MessageID
    public let role: MessageRole
    public let text: String
    /// Who said it: the person who wrote it, or the agent that answered.
    public let author: ParticipantSummary?
    /// Who it was said to: none for no one in particular.
    public let to: [ParticipantRef]
    /// When it was said.
    public let at: Date

    public init(
        id: MessageID, role: MessageRole, text: String, author: ParticipantSummary? = nil, to: [ParticipantRef] = [],
        at: Date
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.author = author
        self.to = to
        self.at = at
    }
}

/// An agent's reply while it's typed: what's written so far, under the id it's said with.
public struct ReplySoFar: Codable, Equatable, Sendable, Identifiable {
    public let id: MessageID
    public let text: String
    /// The agent typing it.
    public let author: ParticipantSummary?

    public init(id: MessageID, text: String, author: ParticipantSummary? = nil) {
        self.id = id
        self.text = text
        self.author = author
    }
}

/// A conversation to start: in the space `spaceID`, answered by its bot `botID`, or its main one.
public struct CreateConversationRequest: Codable, Equatable, Sendable {
    public let botID: BotID?
    /// The space it starts in.
    public let spaceID: SpaceID

    public init(botID: BotID? = nil, spaceID: SpaceID) {
        self.botID = botID
        self.spaceID = spaceID
    }
}

public struct SendMessageRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: MessageID
    public let text: String
    /// Who it's said to: none for no one in particular, which the conversation's agent answers. Said
    /// only to people, no agent answers it.
    public let to: [ParticipantRef]

    public init(id: MessageID, text: String, to: [ParticipantRef] = []) {
        self.id = id
        self.text = text
        self.to = to
    }

    private enum CodingKeys: String, CodingKey { case id, text, to }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(MessageID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        // Said to no one in particular unless it says who.
        to = try values.decodeIfPresent([ParticipantRef].self, forKey: .to) ?? []
    }
}

public typealias ChatMessageRequest = SendMessageRequest

/// An admin's answer to an access request.
public enum AccessAnswer: String, Codable, Sendable {
    /// It runs once, the next time it's asked for.
    case once
    /// It runs whenever whoever asked asks, from now on.
    case always
    /// It runs whenever anyone in the conversation asks, from now on.
    case everyone
    case no
}

/// Someone in the conversation asked its admins to allow exactly what they may not do yet.
public struct AccessRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// Exactly what was asked for, as people read it, such as `GET https://example.com`.
    public let request: String

    public init(id: UUID, request: String) {
        self.id = id
        self.request = request
    }
}

public enum ConversationStatus: String, Codable, Sendable {
    case idle
    case running
    case failed
}

public enum ConversationPhase: String, Codable, Sendable {
    case thinking
    case typing
}

public struct ChatError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
