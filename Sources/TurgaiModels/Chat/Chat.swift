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
    /// Its title, or else the first line of the first thing said in it: none until either.
    public let title: String?
    /// The space it's in.
    public let spaceID: String

    public init(id: ConversationID, botID: BotID, title: String? = nil, spaceID: String) {
        self.id = id
        self.botID = botID
        self.title = title
        self.spaceID = spaceID
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

/// A conversation to start: answered by `botID`, or the default bot, in the space `spaceID`, or
/// Turgai's own.
public struct CreateConversationRequest: Codable, Equatable, Sendable {
    public let botID: BotID?
    public let spaceID: String?

    public init(botID: BotID? = nil, spaceID: String? = nil) {
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

/// What a client sends over the chat socket.
public enum ChatCommand: Codable, Equatable, Sendable {
    /// The conversation the connection shows from now on, instead of the one before: its history
    /// and live turns come, and messages and answers go to it.
    case open(conversationID: ConversationID)
    case message(SendMessageRequest)
    /// An admin's answer to an access request.
    case answer(id: UUID, answer: AccessAnswer)
    /// Something asked, answered by a reply carrying `ref`.
    case push(ref: PushRef, ask: ChatAsk)

    private enum Kind: String, Codable {
        case open
        case message
        case answer
        case push
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, text, to, answer, conversationID
        case ref, ask, topic, remembering
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .open:
            self = .open(conversationID: try values.decode(ConversationID.self, forKey: .conversationID))
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
            let ask: ChatAsk =
                switch try values.decode(ChatAsk.Name.self, forKey: .ask) {
                case .join: .join(try values.decode(ChatTopic.self, forKey: .topic))
                case .leave: .leave(try values.decode(ChatTopic.self, forKey: .topic))
                case .memory: .memory
                case .forgetMemory: .forgetMemory
                case .setRemembering:
                    .setRemembering(try values.decode(MemorySummary.Remembering.self, forKey: .remembering))
                }
            self = .push(ref: try values.decode(PushRef.self, forKey: .ref), ask: ask)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .open(let conversationID):
            try values.encode(Kind.open, forKey: .type)
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
            case .join(let topic), .leave(let topic): try values.encode(topic, forKey: .topic)
            case .setRemembering(let remembering): try values.encode(remembering, forKey: .remembering)
            case .memory, .forgetMemory: break
            }
        }
    }
}

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
    case accessRequested = "access.requested"
    case accessAnswered = "access.answered"
    case notice
    case turns
    case turnStep = "turn.step"
    case conversationJoined = "conversation.joined"
    case conversationSaid = "conversation.said"
    case conversationTitled = "conversation.titled"
    case conversationLeft = "conversation.left"
    case reply
    case memoryChanged = "memory.changed"
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
        /// The conversation is open.
        /// The conversation is open, for `you`: the id of the person the client is.
        case ready(
            conversationID: ConversationID,
            botID: BotID,
            status: ConversationStatus,
            you: String
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
            reply: ReplySoFar
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
        /// Someone asked the conversation's admins for access.
        case accessRequested(
            conversationID: ConversationID,
            request: AccessRequest
        )
        /// An admin answered it.
        case accessAnswered(
            conversationID: ConversationID,
            requestID: UUID,
            answer: AccessAnswer
        )
        case notice(
            conversationID: ConversationID?,
            turnID: TurnID?,
            error: ChatError
        )
        /// The agent's past turns, step by step, sent when a client connects.
        case turns(conversationID: ConversationID, turns: [TurnRecord])
        /// One step of the turn running now.
        case turnStep(conversationID: ConversationID, turnID: TurnID, step: TurnStep)
        /// The person is in one more conversation, as it's listed now.
        case conversationJoined(conversation: Conversation)
        /// Something was said in one of the person's other conversations, as it's listed now.
        case conversationSaid(conversation: Conversation)
        /// One of the person's conversations is called something else, as it's listed now.
        case conversationTitled(conversation: Conversation)
        /// The person is no longer in one of their conversations.
        case conversationLeft(conversationID: ConversationID)
        /// The answer to the push `ref`.
        case reply(ref: PushRef, reply: ChatReply)
        /// What's remembered about the person changed, or whether they're remembered: to a connection
        /// that joined ``ChatTopic/memory``.
        case memoryChanged

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
            case .accessRequested: .accessRequested
            case .accessAnswered: .accessAnswered
            case .notice: .notice
            case .turns: .turns
            case .turnStep: .turnStep
            case .conversationJoined: .conversationJoined
            case .conversationSaid: .conversationSaid
            case .conversationTitled: .conversationTitled
            case .conversationLeft: .conversationLeft
            case .reply: .reply
            case .memoryChanged: .memoryChanged
            }
        }
    }

    public let payload: Payload

    public init(payload: Payload) {
        self.payload = payload
    }

    public var type: ChatEventKind { payload.type }

    private enum CodingKeys: String, CodingKey {
        case type, conversationID, botID, turnID, you
        case status, phase, activity, message, messages, error, reply
        case request, requestID, answer
        case turns, step, conversation
        case ref, memory
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(ChatEventKind.self, forKey: .type)

        switch type {
        case .ready:
            payload = .ready(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                botID: try values.decode(BotID.self, forKey: .botID),
                status: try values.decode(ConversationStatus.self, forKey: .status),
                you: try values.decode(String.self, forKey: .you)
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
                reply: try values.decode(ReplySoFar.self, forKey: .reply)
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
        case .accessRequested:
            payload = .accessRequested(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                request: try values.decode(AccessRequest.self, forKey: .request)
            )
        case .accessAnswered:
            payload = .accessAnswered(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                requestID: try values.decode(UUID.self, forKey: .requestID),
                answer: try values.decode(AccessAnswer.self, forKey: .answer)
            )
        case .notice:
            payload = .notice(
                conversationID: try values.decodeIfPresent(ConversationID.self, forKey: .conversationID),
                turnID: try values.decodeIfPresent(TurnID.self, forKey: .turnID),
                error: try values.decode(ChatError.self, forKey: .error)
            )
        case .turns:
            payload = .turns(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turns: try values.decode([TurnRecord].self, forKey: .turns)
            )
        case .conversationJoined:
            payload = .conversationJoined(conversation: try values.decode(Conversation.self, forKey: .conversation))
        case .conversationSaid:
            payload = .conversationSaid(conversation: try values.decode(Conversation.self, forKey: .conversation))
        case .conversationTitled:
            payload = .conversationTitled(conversation: try values.decode(Conversation.self, forKey: .conversation))
        case .conversationLeft:
            payload = .conversationLeft(conversationID: try values.decode(ConversationID.self, forKey: .conversationID))
        case .reply:
            let reply: ChatReply =
                switch try values.decode(ChatReply.Status.self, forKey: .status) {
                case .ok:
                    try values.decodeIfPresent(MemorySummary.self, forKey: .memory).map(ChatReply.memory) ?? .ok
                case .failed: .failed(try values.decode(ChatError.self, forKey: .error))
                }
            payload = .reply(ref: try values.decode(PushRef.self, forKey: .ref), reply: reply)
        case .memoryChanged:
            payload = .memoryChanged
        case .turnStep:
            payload = .turnStep(
                conversationID: try values.decode(ConversationID.self, forKey: .conversationID),
                turnID: try values.decode(TurnID.self, forKey: .turnID),
                step: try values.decode(TurnStep.self, forKey: .step)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)

        switch payload {
        case .ready(let conversationID, let botID, let status, let you):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(botID, forKey: .botID)
            try values.encode(status, forKey: .status)
            try values.encode(you, forKey: .you)
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
        case .turnPartial(let conversationID, let turnID, let reply):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(reply, forKey: .reply)
        case .turnCompleted(let conversationID, let turnID, let message):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(message, forKey: .message)
        case .turnFailed(let conversationID, let turnID, let error):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(error, forKey: .error)
        case .accessRequested(let conversationID, let request):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(request, forKey: .request)
        case .accessAnswered(let conversationID, let requestID, let answer):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(requestID, forKey: .requestID)
            try values.encode(answer, forKey: .answer)
        case .notice(let conversationID, let turnID, let error):
            try values.encodeIfPresent(conversationID, forKey: .conversationID)
            try values.encodeIfPresent(turnID, forKey: .turnID)
            try values.encode(error, forKey: .error)
        case .turns(let conversationID, let turns):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turns, forKey: .turns)
        case .turnStep(let conversationID, let turnID, let step):
            try values.encode(conversationID, forKey: .conversationID)
            try values.encode(turnID, forKey: .turnID)
            try values.encode(step, forKey: .step)
        case .conversationJoined(let conversation), .conversationSaid(let conversation),
            .conversationTitled(let conversation):
            try values.encode(conversation, forKey: .conversation)
        case .conversationLeft(let conversationID):
            try values.encode(conversationID, forKey: .conversationID)
        case .reply(let ref, let reply):
            try values.encode(ref, forKey: .ref)
            switch reply {
            case .ok:
                try values.encode(ChatReply.Status.ok, forKey: .status)
            case .memory(let memory):
                try values.encode(ChatReply.Status.ok, forKey: .status)
                try values.encode(memory, forKey: .memory)
            case .failed(let error):
                try values.encode(ChatReply.Status.failed, forKey: .status)
                try values.encode(error, forKey: .error)
            }
        case .memoryChanged:
            break
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
