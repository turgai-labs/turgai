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
    public let botID: BotID

    public init(id: ConversationID, botID: BotID) {
        self.id = id
        self.botID = botID
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

    public init(id: MessageID, role: MessageRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct CreateConversationRequest: Codable, Equatable, Sendable {
    public let botID: BotID?

    public init(botID: BotID? = nil) {
        self.botID = botID
    }
}

public struct SendMessageRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: MessageID
    public let text: String

    public init(id: MessageID, text: String) {
        self.id = id
        self.text = text
    }
}

public typealias ChatMessageRequest = SendMessageRequest

public enum ChatEventKind: String, Codable, Sendable {
    case ready
    case history
    case messageAccepted = "message.accepted"
    case turnStarted = "turn.started"
    case turnPhase = "turn.phase"
    case turnStatus = "turn.status"
    case turnPartial = "turn.partial"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case notice
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

public struct ChatEvent: Codable, Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        case ready(
            conversationID: ConversationID,
            botID: BotID,
            status: ConversationStatus
        )
        case history(
            conversationID: ConversationID,
            messages: [Message]
        )
        case messageAccepted(
            conversationID: ConversationID,
            turnID: TurnID?,
            message: Message
        )
        case turnStarted(conversationID: ConversationID, turnID: TurnID)
        case turnPhase(
            conversationID: ConversationID,
            turnID: TurnID,
            phase: ConversationPhase
        )
        case turnStatus(
            conversationID: ConversationID,
            turnID: TurnID,
            activity: String
        )
        case turnPartial(
            conversationID: ConversationID,
            turnID: TurnID,
            message: Message
        )
        case turnCompleted(
            conversationID: ConversationID,
            turnID: TurnID,
            message: Message
        )
        case turnFailed(
            conversationID: ConversationID,
            turnID: TurnID?,
            error: ChatError
        )
        case notice(
            conversationID: ConversationID?,
            turnID: TurnID?,
            error: ChatError
        )

        public var type: ChatEventKind {
            switch self {
            case .ready: .ready
            case .history: .history
            case .messageAccepted: .messageAccepted
            case .turnStarted: .turnStarted
            case .turnPhase: .turnPhase
            case .turnStatus: .turnStatus
            case .turnPartial: .turnPartial
            case .turnCompleted: .turnCompleted
            case .turnFailed: .turnFailed
            case .notice: .notice
            }
        }
    }

    public let payload: Payload

    public init(payload: Payload) {
        self.payload = payload
    }

    public var type: ChatEventKind { payload.type }

    private enum CodingKeys: String, CodingKey {
        case type, conversationID, botID, turnID
        case status, phase, activity, message, messages, error
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(ChatEventKind.self, forKey: .type)

        switch type {
        case .ready:
            payload = .ready(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                botID: try values.decode(BotID.self, forKey: .botID),
                status: try values.decode(ConversationStatus.self, forKey: .status)
            )
        case .history:
            payload = .history(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                messages: try values.decode([Message].self, forKey: .messages)
            )
        case .messageAccepted:
            payload = .messageAccepted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                message: try values.decode(Message.self, forKey: .message)
            )
        case .turnStarted:
            payload = .turnStarted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID)
            )
        case .turnPhase:
            payload = .turnPhase(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                phase: try values.decode(ConversationPhase.self, forKey: .phase)
            )
        case .turnStatus:
            payload = .turnStatus(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                activity: try values.decode(String.self, forKey: .activity)
            )
        case .turnPartial:
            payload = .turnPartial(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                message: try values.decode(Message.self, forKey: .message)
            )
        case .turnCompleted:
            payload = .turnCompleted(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                message: try values.decode(Message.self, forKey: .message)
            )
        case .turnFailed:
            payload = .turnFailed(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                error: try values.decode(ChatError.self, forKey: .error)
            )
        case .notice:
            payload = .notice(
                conversationID: try values.decodeIfPresent(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                error: try values.decode(ChatError.self, forKey: .error)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)

        switch payload {
        case .ready(let conversationID, let botID, let status):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(botID, forKey: .botID)
            try values.encode(status, forKey: .status)
        case .history(let conversationID, let messages):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(messages, forKey: .messages)
        case .messageAccepted(let conversationID, let turnID, let message):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(message, forKey: .message)
        case .turnStarted(let conversationID, let turnID):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
        case .turnPhase(let conversationID, let turnID, let phase):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(phase, forKey: .phase)
        case .turnStatus(let conversationID, let turnID, let activity):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(activity, forKey: .activity)
        case .turnPartial(let conversationID, let turnID, let message),
            .turnCompleted(let conversationID, let turnID, let message):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(message, forKey: .message)
        case .turnFailed(let conversationID, let turnID, let error):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(error, forKey: .error)
        case .notice(let conversationID, let turnID, let error):
            try values.encodeIfPresent(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(error, forKey: .error)
        }
    }
}

public struct ChatError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
