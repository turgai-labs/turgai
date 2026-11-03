#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct ChannelID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    /// Identifies one configured connection of a provider. This keeps two
    /// Telegram bots serving the same external chat in separate conversations.
    public init(provider: String, instanceID: String) {
        self.rawValue = "\(provider)/\(instanceID)"
    }

    public var providerName: String {
        String(rawValue.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    public var instanceID: String {
        let parts = rawValue.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "" }
        return String(parts[1])
    }
}

public struct ExternalConversationAddress: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }
}

/// Identity of a participant within one channel.
///
/// The channel is part of the value so Telegram user `42` cannot collide with
/// Discord user `42`. The unlabeled initializer remains a migration and test
/// convenience for values created before channel scoping was introduced.
public struct ParticipantID: RawRepresentable, Hashable, Codable, Sendable {
    public let channel: ChannelID
    public let rawValue: String

    public init(rawValue: String) {
        self.channel = ChannelID("unknown")
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public init(channel: ChannelID, rawValue: String) {
        self.channel = channel
        self.rawValue = rawValue
    }

    public var stableKey: String {
        "\(channel.rawValue):\(rawValue)"
    }

    public static func == (lhs: ParticipantID, rhs: ParticipantID) -> Bool {
        lhs.channel == rhs.channel && lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(channel)
        hasher.combine(rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case channel
        case rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.channel =
            try container.decodeIfPresent(ChannelID.self, forKey: .channel)
            ?? ChannelID("unknown")
        self.rawValue = try container.decode(String.self, forKey: .rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channel, forKey: .channel)
        try container.encode(rawValue, forKey: .rawValue)
    }
}

public struct MessageID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TurnID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ConversationID: Hashable, Codable, Sendable {
    public let channel: ChannelID
    public let externalAddress: ExternalConversationAddress

    public init(
        channel: ChannelID,
        externalAddress: ExternalConversationAddress
    ) {
        self.channel = channel
        self.externalAddress = externalAddress
    }

    public init?(stableKey: String) {
        guard let separator = stableKey.firstIndex(of: ":") else {
            return nil
        }

        let channel = String(stableKey[..<separator])
        let addressStart = stableKey.index(after: separator)
        let externalAddress = String(stableKey[addressStart...])
        guard !channel.isEmpty, !externalAddress.isEmpty else {
            return nil
        }

        self.init(
            channel: ChannelID(channel),
            externalAddress: ExternalConversationAddress(externalAddress)
        )
    }

    public var stableKey: String {
        "\(channel.rawValue):\(externalAddress.rawValue)"
    }

}

/// Stable event-store identity for a conversation.
///
/// The raw string is used only at the EventSourcing boundary. Keeping the
/// conversation identity alongside it prevents callers from passing an
/// arbitrary journal ID or duplicating the prefix/parsing rules.
public struct ConversationPersistenceID: RawRepresentable, Hashable, Codable, Sendable {
    public static let prefix = "turgai-conversation-"

    public let rawValue: String
    public let conversationID: ConversationID

    public init(conversationID: ConversationID) {
        self.conversationID = conversationID
        self.rawValue = "\(Self.prefix)\(conversationID.stableKey)"
    }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix(Self.prefix) else { return nil }
        let stableKey = String(rawValue.dropFirst(Self.prefix.count))
        guard let conversationID = ConversationID(stableKey: stableKey) else {
            return nil
        }
        self.init(conversationID: conversationID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid conversation persistence ID"
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum AttachmentKind: String, Codable, Sendable {
    case image
    case file
}

/// What a conversation's channel calls something attached to one of its messages: Telegram's
/// non-secret `file_id`. It names it only through the channel that conversation is in; credentials
/// and temporary download URLs never become part of it.
public struct AttachmentID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A media reference attached to a conversation message.
///
/// Messages persist only its id and descriptive metadata. The conversation's
/// channel gets it when the agent asks for it; neither credentials, temporary
/// URLs, nor bytes are persisted here.
public struct Attachment: Hashable, Codable, Sendable {
    public let id: AttachmentID
    public let kind: AttachmentKind
    public let filename: String?
    public let mimeType: String?

    public init(
        id: AttachmentID,
        kind: AttachmentKind,
        filename: String? = nil,
        mimeType: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// Human-facing metadata attached to an inbound message.
///
/// This is deliberately separate from ``UserID``: names and handles can
/// change, while the identity used for persistence and memory must remain
/// stable.
public struct MessageAuthor: Hashable, Codable, Sendable {
    public let displayName: String?
    public let handle: String?

    public init(
        displayName: String? = nil,
        handle: String? = nil
    ) {
        self.displayName = Self.normalized(displayName)
        self.handle = Self.normalized(handle)
    }

    public var isEmpty: Bool {
        displayName == nil && handle == nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmed()
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A message's id in the channel it came through, as the channel names it: what the channel finds
/// it by again.
public struct ChannelMessageID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A person's message something was noted from for their memory: by its id, and by its id in its
/// channel, when the channel gave it one.
public struct NotedMessage: Hashable, Codable, Sendable {
    public let id: MessageID
    public let channelID: ChannelMessageID?

    public init(id: MessageID, channelID: ChannelMessageID?) {
        self.id = id
        self.channelID = channelID
    }
}

public struct InboundMessage: Hashable, Codable, Sendable {
    public let id: MessageID
    /// Its id in the channel it came through, when the channel gave it one.
    public let channelMessageID: ChannelMessageID?
    public let conversationID: ConversationID
    public let participantID: ParticipantID
    public let userID: UserID
    public let author: MessageAuthor?
    public let text: String
    public let attachments: [Attachment]
    public let receivedAt: Date
    /// Who it's said to: none for no one in particular, which its agent answers.
    public let to: Set<Participant>

    public init(
        id: MessageID = MessageID(),
        channelMessageID: ChannelMessageID? = nil,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID,
        author: MessageAuthor? = nil,
        text: String,
        attachments: [Attachment] = [],
        receivedAt: Date,
        to: Set<Participant> = []
    ) {
        self.id = id
        self.channelMessageID = channelMessageID
        self.conversationID = conversationID
        self.participantID = participantID
        self.userID = userID
        self.author = author?.isEmpty == true ? nil : author
        self.text = text
        self.attachments = attachments
        self.receivedAt = receivedAt
        self.to = to
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(channelMessageID, forKey: .channelMessageID)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(participantID, forKey: .participantID)
        try container.encode(userID, forKey: .userID)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(receivedAt, forKey: .receivedAt)
        try container.encode(to, forKey: .to)
    }
}

/// A transient input delivered to a live Turgai session.
///
/// Channel adapters translate their provider-specific updates into this
/// value before they enter the application connection layer.
public enum ConversationCommand: Sendable, Equatable {
    /// `/link`: a code to link this way in with another, or one entered from it.
    case link(
        LinkAsk,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case reminders(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case tasks(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case pauseTask(
        id: String,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case unpauseTask(
        id: String,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case cancelTask(
        id: String,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case cancelReminder(
        id: String,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    /// The objects the person may read here, each to show.
    case objects(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    /// One of those objects, by its id, shown as its card.
    case object(
        id: String,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    /// One of the person's remembered facts, by its id, forgotten.
    case forgetFact(
        id: String,
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    /// What the person says is remembered again.
    case memoryOn(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    /// What the person says is no longer remembered.
    case memoryOff(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
}

public enum ConversationInput: Sendable, Equatable {
    case message(
        InboundMessage,
        turnID: TurnID
    )
    case connect(ConversationID)
    /// The session no longer shown what happens in it.
    case detach(ConversationID)
    /// `by` emptying it.
    case reset(ConversationID, by: UserID)
    /// Someone answered an access request of its space, as the link they answered through says.
    case answer(conversationID: ConversationID, AccessRequestID, AccessAnswer, by: UserID)
    case memory(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case forget(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case context(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case diagnose(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case command(ConversationCommand)
    /// Its chat as its platform says it is, said by `by` writing in it: what it's called, and who
    /// decides for it.
    case chat(conversationID: ConversationID, named: SpaceName, admins: Set<UserID>, by: UserID)
}

public struct PendingConversationMessage: Hashable, Codable, Sendable {
    public let message: InboundMessage
    public let turnID: TurnID
    public let agentRole: String

    public init(message: InboundMessage, turnID: TurnID, agentRole: String) {
        self.message = message
        self.turnID = turnID
        self.agentRole = agentRole
    }
}

/// A reply that satisfies the conversational channel contract.
public struct ConversationReply: Hashable, Codable, Sendable {
    public let text: String

    public init?(_ text: String) {
        let normalized = text.trimmed()
        guard !normalized.isEmpty else {
            return nil
        }
        self.text = normalized
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let reply = Self(text) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Conversation reply cannot be empty"
                )
            )
        }
        self = reply
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

/// The successful result of one model operation.
///
/// A model operation may complete without a conversational message. That is an
/// explicit domain outcome for work that intentionally has no reply; it is not
/// the representation of an empty model string.
public enum ConversationCompletion: Hashable, Codable, Sendable {
    case reply(ConversationReply)
    case `void`
}

/// A model response that has been durably produced but has not yet been
/// acknowledged by a channel connection.
public struct PendingConversationReply: Hashable, Codable, Sendable {
    public let turnID: TurnID
    public let reply: ConversationReply

    public init(turnID: TurnID, reply: ConversationReply) {
        self.turnID = turnID
        self.reply = reply
    }

    public var text: String {
        reply.text
    }
}

/// An agent's profile: which agent it is that answers.
public struct AgentProfileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Someone in a conversation: a person, or an agent.
public enum Participant: Hashable, Codable, Sendable {
    case person(UserID)
    case agent(AgentProfileID)
}

/// A conversation as one of its people reads it: the space it's in, and who's in it.
public struct ConversationOutline: Hashable, Codable, Sendable {
    public let space: SpaceID
    public let participants: Set<Participant>

    public init(space: SpaceID, participants: Set<Participant>) {
        self.space = space
        self.participants = participants
    }

    /// The agent that answers in it: for now, a conversation has exactly one.
    public var agent: AgentProfileID? {
        participants.lazy.compactMap { if case .agent(let agent) = $0 { agent } else { nil } }.first
    }
}

/// What a conversation is called, as one of its people titles it.
public struct ConversationTitle: Hashable, Codable, Sendable, CustomStringConvertible {
    public static let maximumLength = 80

    public let rawValue: String

    /// The title `written`, without the space around it: none when there's nothing, or too much.
    public init?(_ written: String) {
        let title = written.trimmed()
        guard !title.isEmpty, title.count <= Self.maximumLength else { return nil }
        self.rawValue = title
    }

    public var description: String { rawValue }
}

/// Why a conversation didn't do what it was asked.
public enum ConversationRefusal: Error, Equatable, Codable, Sendable, CustomStringConvertible {
    /// It hasn't started: nothing's in it yet.
    case notStarted
    /// It started already, once and for all.
    case alreadyStarted
    /// They're not one of its people.
    case notInIt
    /// A guest neither adds anyone to a conversation nor is added to one.
    case guestsStayOut
    /// It has its agent: for now, a conversation has one.
    case oneAgentForNow
    /// Someone a message is said to isn't in it.
    case addresseeNotInIt

    public var description: String {
        switch self {
        case .notStarted: "This conversation hasn't started."
        case .alreadyStarted: "This conversation has started already."
        case .notInIt: "You're not in this conversation."
        case .guestsStayOut: "A guest can't add anyone to a conversation, or be added to one."
        case .oneAgentForNow: "This conversation has its agent: for now, a conversation has one."
        case .addresseeNotInIt: "Someone it's said to isn't in this conversation."
        }
    }
}

public enum ConversationEvent: Codable, Sendable, Equatable {
    /// It started, in `space`: the space it's in from then on.
    case started(in: SpaceID)
    /// Someone is in it: a person, who reads it and writes in it, or an agent, who answers in it.
    case joined(Participant)
    /// Someone left it: it's off their list, and they no longer read it.
    case left(Participant)
    /// One of its people titled it.
    case titled(ConversationTitle)
    /// One of its people said something to others in it, which no agent answers.
    case said(InboundMessage)
    /// Its agent's inbox: a message waiting, or a turn starting or ending.
    case inbox(AgentInboxEvent)
    /// The turn answering `message` needed what its scope didn't allow, which its space's admins
    /// are asked for: the answer continues it.
    case awaiting(AccessRequestID, PendingConversationMessage)
    /// The answer to it came, and continues the turn that waited.
    case answered(AccessRequestID)
    case replyQueued(PendingConversationReply)
    case replyDelivered(TurnID)
    case reset
    /// Something was noted from `message` for its author's memory: it's marked until it's unmarked.
    case noted(NotedMessage)
    /// The noted message's mark was taken off.
    case unnoted
}

/// The durable history of one conversation, read by an infrastructure adapter
/// and consumed by application recovery logic.
public struct ConversationJournal: Sendable, Equatable {
    public let conversationID: ConversationID
    public let events: [ConversationEvent]

    public init(
        conversationID: ConversationID,
        events: [ConversationEvent]
    ) {
        self.conversationID = conversationID
        self.events = events
    }
}

public enum ConversationFailureKind: String, Codable, Sendable {
    case model
    case cancelled
    case invalidInput
    case unknown
}

public struct ConversationFailure: Error, Hashable, Codable, Sendable {
    public let kind: ConversationFailureKind
    public let message: String

    public init(kind: ConversationFailureKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public enum ConversationStatus: Hashable, Codable, Sendable {
    case idle
    case running(TurnID)
    case failed(ConversationFailure)
}

public enum ConversationHistoryRole: String, Codable, Sendable {
    case user
    case assistant
}

public struct ConversationHistoryEntry: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let role: ConversationHistoryRole
    public let text: String
    /// Who said it: the person who wrote it, or the agent that answered; none for what no one said,
    /// such as a turn that failed.
    public let author: Participant?
    /// Who it was said to: none for no one in particular.
    public let to: Set<Participant>

    public init(
        id: String, role: ConversationHistoryRole, text: String, author: Participant? = nil,
        to: Set<Participant> = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.author = author
        self.to = to
    }
}

/// One agent's inbox in a conversation: the messages waiting for it, the one it's answering, and
/// how its last turn ended. It answers one at a time.
public struct AgentInbox: Hashable, Codable, Sendable {
    public internal(set) var status: ConversationStatus = .idle
    /// The messages it took, the last 256: one sent again isn't taken twice.
    public internal(set) var acceptedMessageIDs: [MessageID] = []
    public internal(set) var pendingMessages: [PendingConversationMessage] = []
    public internal(set) var activeMessage: PendingConversationMessage?

    public init() {}

    public var activeTurnID: TurnID? {
        guard case .running(let turnID) = status else { return nil }
        return turnID
    }

    /// The inbox after `event`: the one place it changes.
    public func applying(_ event: AgentInboxEvent) -> AgentInbox {
        var next = self
        switch event {
        case .queued(let pending):
            next.accept(pending.message.id)
            next.pendingMessages.append(pending)
        case .turnStarted(let pending):
            next.accept(pending.message.id)
            if let index = next.pendingMessages.firstIndex(where: { $0.turnID == pending.turnID }) {
                next.pendingMessages.remove(at: index)
            }
            next.activeMessage = pending
            next.status = .running(pending.turnID)
        case .turnCompleted(let turnID):
            guard activeTurnID == turnID else { return self }
            next.activeMessage = nil
            next.status = .idle
        case .turnFailed(let turnID, let failure):
            guard activeTurnID == turnID else { return self }
            next.activeMessage = nil
            next.status = .failed(failure)
        }
        return next
    }

    /// The inbox once the turn on `turnID` has its reply: the reply ends the turn, before its
    /// completion is journaled, so a crash between the two can't lose it.
    func answered(_ turnID: TurnID) -> AgentInbox {
        guard activeTurnID == turnID else { return self }
        var next = self
        next.activeMessage = nil
        next.status = .idle
        return next
    }

    /// The inbox reset: nothing waiting, and no turn.
    func emptied() -> AgentInbox {
        var next = self
        next.activeMessage = nil
        next.pendingMessages.removeAll(keepingCapacity: true)
        next.status = .idle
        return next
    }

    private mutating func accept(_ messageID: MessageID) {
        guard !acceptedMessageIDs.contains(messageID) else { return }
        acceptedMessageIDs.append(messageID)
        if acceptedMessageIDs.count > 256 {
            acceptedMessageIDs.removeFirst(acceptedMessageIDs.count - 256)
        }
    }
}

/// What happened in an agent's inbox.
public enum AgentInboxEvent: Hashable, Codable, Sendable {
    /// A message waits while another is answered.
    case queued(PendingConversationMessage)
    case turnStarted(PendingConversationMessage)
    case turnCompleted(TurnID)
    case turnFailed(TurnID, ConversationFailure)
}

public struct ConversationState: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    /// The space it started in: none until it has. It never changes after.
    public internal(set) var space: SpaceID?
    /// Who's in it: its people, and its agents.
    public internal(set) var participants: Set<Participant> = []
    /// What it's called, once one of its people titled it.
    public internal(set) var title: ConversationTitle?
    /// Its agent's inbox.
    public internal(set) var inbox: AgentInbox
    /// The turns that wait for an answer from its space's admins, by what each asked for.
    public internal(set) var awaiting: [AccessRequestID: PendingConversationMessage]
    public internal(set) var pendingReplies: [PendingConversationReply]
    public internal(set) var history: [ConversationHistoryEntry]
    /// The message marked as noted for its author's memory, until its mark is taken off.
    public internal(set) var noted: NotedMessage?

    public init(
        conversationID: ConversationID,
        inbox: AgentInbox = AgentInbox(),
        awaiting: [AccessRequestID: PendingConversationMessage] = [:],
        pendingReplies: [PendingConversationReply] = [],
        history: [ConversationHistoryEntry] = []
    ) {
        self.conversationID = conversationID
        self.inbox = inbox
        self.awaiting = awaiting
        self.pendingReplies = pendingReplies
        self.history = history
    }

    public mutating func apply(_ event: ConversationEvent) {
        switch event {
        case .started(let space):
            self.space = space

        case .joined(let participant):
            participants.insert(participant)

        case .left(let participant):
            participants.remove(participant)

        case .titled(let title):
            self.title = title

        case .said(let message):
            appendUserMessage(message)

        case .awaiting(let id, let message):
            awaiting[id] = message

        case .answered(let id):
            awaiting[id] = nil

        case .inbox(let event):
            switch event {
            case .queued(let pending), .turnStarted(let pending):
                appendUserMessage(pending.message)
            case .turnFailed(let turnID, let failure) where inbox.activeTurnID == turnID:
                appendHistory(
                    ConversationHistoryEntry(
                        id: "failure:\(turnID.rawValue.uuidString)",
                        role: .assistant,
                        text: failure.message
                    )
                )
            case .turnFailed, .turnCompleted:
                break
            }
            inbox = inbox.applying(event)

        case .replyQueued(let pending):
            if !pendingReplies.contains(pending) {
                pendingReplies.append(pending)
            }
            // Said by the agent whose turn it was.
            let answering = inbox.activeMessage.flatMap { $0.turnID == pending.turnID ? $0.agentRole : nil }
            let agent = answering.map(AgentProfileID.init) ?? agents.first
            inbox = inbox.answered(pending.turnID)
            appendHistory(
                ConversationHistoryEntry(
                    id: "reply:\(pending.turnID.rawValue.uuidString)",
                    role: .assistant,
                    text: pending.text,
                    author: agent.map(Participant.agent)
                )
            )

        case .replyDelivered(let turnID):
            pendingReplies.removeAll { $0.turnID == turnID }

        case .reset:
            inbox = inbox.emptied()
            pendingReplies.removeAll(keepingCapacity: true)
            history.removeAll(keepingCapacity: true)

        case .noted(let message):
            noted = message

        case .unnoted:
            noted = nil
        }
    }

    /// The people in it: who reads it and writes in it.
    public var people: Set<UserID> {
        Set(participants.compactMap { if case .person(let person) = $0 { person } else { nil } })
    }

    /// The agents in it: who answers in it. For now, once it has started, exactly one.
    public var agents: Set<AgentProfileID> {
        Set(participants.compactMap { if case .agent(let agent) = $0 { agent } else { nil } })
    }

    /// It started in `space`, with `agent` answering in it and `person` the first of its people:
    /// refused when it has started already.
    public func starting(in space: SpaceID, answeredBy agent: AgentProfileID, by person: UserID)
        throws(ConversationRefusal) -> [ConversationEvent]
    {
        guard self.space == nil else { throw .alreadyStarted }
        return [.started(in: space), .joined(.agent(agent)), .joined(.person(person))]
    }

    /// `person` one of its people, as someone writing in its chat is: none for someone already in it.
    public func admitting(_ person: UserID) -> ConversationEvent? {
        participants.contains(.person(person)) ? nil : .joined(.person(person))
    }

    /// `participant` in it, as `adder`, one of its people, adds them: refused for a guest either
    /// way, and for a second agent; none for someone in it already.
    public func adding(_ participant: Participant, by adder: UserID) throws(ConversationRefusal) -> [ConversationEvent] {
        _ = try reading(by: adder)
        guard !participants.contains(participant) else { return [] }
        switch participant {
        case .person(let person):
            guard !adder.isGuest, !person.isGuest else { throw .guestsStayOut }
        case .agent:
            guard agents.isEmpty else { throw .oneAgentForNow }
        }
        return [.joined(participant)]
    }

    /// Whether its agent answers `message`, said by one of its people: when it's said to no one in
    /// particular, or to its agent among others. Refused when it's said to someone not in it.
    public func answers(_ message: InboundMessage) throws(ConversationRefusal) -> Bool {
        _ = try reading(by: message.userID)
        guard message.to.isSubset(of: participants) else { throw .addresseeNotInIt }
        return message.to.isEmpty || message.to.contains { if case .agent = $0 { true } else { false } }
    }

    /// `message` said in it to the people it names, which no agent answers: none when it's been
    /// said already.
    public func saying(_ message: InboundMessage) -> [ConversationEvent] {
        history.contains { $0.id == "message:\(message.id.rawValue.uuidString)" } ? [] : [.said(message)]
    }

    /// `person` leaving it: refused unless they're one of its people. Its agent stays.
    public func leaving(_ person: UserID) throws(ConversationRefusal) -> [ConversationEvent] {
        _ = try reading(by: person)
        return [.left(.person(person))]
    }

    /// It called `title`, as `person`, one of its people, titles it: none when it's called that.
    public func titling(_ title: ConversationTitle, by person: UserID) throws(ConversationRefusal)
        -> [ConversationEvent]
    {
        _ = try reading(by: person)
        return self.title == title ? [] : [.titled(title)]
    }

    /// It as `person` reads it or writes in it: refused when it hasn't started, or they're not one
    /// of its people.
    public func reading(by person: UserID) throws(ConversationRefusal) -> ConversationOutline {
        guard let space else { throw .notStarted }
        guard participants.contains(.person(person)) else { throw .notInIt }
        return ConversationOutline(space: space, participants: participants)
    }

    public var requiresRecovery: Bool {
        switch inbox.status {
        case .running:
            true
        case .idle, .failed:
            !inbox.pendingMessages.isEmpty || !pendingReplies.isEmpty
        }
    }

    private mutating func appendUserMessage(_ message: InboundMessage) {
        appendHistory(
            ConversationHistoryEntry(
                id: "message:\(message.id.rawValue.uuidString)",
                role: .user,
                text: message.text,
                author: .person(message.userID),
                to: message.to
            )
        )
    }

    private mutating func appendHistory(_ entry: ConversationHistoryEntry) {
        guard !history.contains(where: { $0.id == entry.id }) else { return }
        history.append(entry)
    }
}

public struct ConversationTurnRequest: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    public let turnID: TurnID
    public let message: InboundMessage
    public let agentRole: String

    public init(
        conversationID: ConversationID,
        turnID: TurnID,
        message: InboundMessage,
        agentRole: String
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.message = message
        self.agentRole = agentRole
    }
}

extension ConversationTurnRequest {
    /// The turn that answers `pending` in the conversation `state` is of: on behalf of its sender.
    init(_ pending: PendingConversationMessage, in state: ConversationState) {
        self.init(
            conversationID: state.conversationID, turnID: pending.turnID, message: pending.message,
            agentRole: pending.agentRole)
    }
}

public enum ReplyPhase: String, Hashable, Codable, Sendable {
    case thinking
    case typing
}

public enum ReplyEvent: Hashable, Codable, Sendable {
    /// A person's message, as it's taken: with the turn that answers it, if one does.
    case userMessage(
        conversationID: ConversationID,
        turnID: TurnID?,
        messageID: MessageID,
        text: String,
        author: UserID,
        to: Set<Participant>
    )
    case started(conversationID: ConversationID, turnID: TurnID)
    case phase(conversationID: ConversationID, turnID: TurnID, phase: ReplyPhase)
    case status(conversationID: ConversationID, turnID: TurnID, message: String)
    /// One thing the agent did, for those watching the turn step by step.
    case step(conversationID: ConversationID, turnID: TurnID, step: ReplyStep)
    case partial(conversationID: ConversationID, turnID: TurnID, text: String)
    case keepAlive(conversationID: ConversationID, turnID: TurnID, phase: ReplyPhase)
    case finished(conversationID: ConversationID, turnID: TurnID, text: String)
    case completed(conversationID: ConversationID, turnID: TurnID)
    case failed(conversationID: ConversationID, turnID: TurnID?, message: String)
}

extension ReplyEvent {
    /// The conversation it happened in.
    public var conversationID: ConversationID {
        switch self {
        case .userMessage(let conversation, _, _, _, _, _), .started(let conversation, _),
            .phase(let conversation, _, _), .status(let conversation, _, _), .step(let conversation, _, _),
            .partial(let conversation, _, _), .keepAlive(let conversation, _, _), .finished(let conversation, _, _),
            .completed(let conversation, _), .failed(let conversation, _, _):
            conversation
        }
    }
}

/// One past turn of the agent: the message that started it, what it did, and how it ended.
public struct ConversationTurn: Hashable, Codable, Sendable {
    public enum Outcome: Hashable, Codable, Sendable {
        case running
        case replied(String, at: Date)
        case failed(String, at: Date)
        case cancelled(at: Date)
        /// Cut off by a restart, and closed instead of resumed.
        case interrupted(at: Date)
    }

    /// The turn's own ID, as its turn events carry it: two turns for one message are two turns.
    public let id: TurnID
    public let message: String
    public let startedAt: Date
    public var steps: [ReplyStep]
    public var outcome: Outcome

    public init(id: TurnID, message: String, startedAt: Date, steps: [ReplyStep] = [], outcome: Outcome = .running) {
        self.id = id
        self.message = message
        self.startedAt = startedAt
        self.steps = steps
        self.outcome = outcome
    }
}

/// One thing the agent did during a turn.
public enum ReplyStep: Hashable, Codable, Sendable {
    /// A tool it called, with its arguments as the model wrote them.
    case toolCalled(name: String, arguments: String, at: Date)
    /// A tool call's result; `failure` says why it failed, when it did.
    case toolFinished(name: String, output: String, failure: String?, at: Date)
    /// What the runtime told the model in the turn, in the words it was told.
    case noticed(words: String, at: Date)
}

public struct OutboundAction: Hashable, Codable, Sendable {
    public let label: String
    public let command: String

    public init(label: String, command: String) {
        self.label = label
        self.command = command
    }
}

public enum OutboundEvent: Hashable, Codable, Sendable {
    case reply(ReplyEvent)
    /// Someone asked its space's admins for access: each link shows it to them.
    case asked(conversationID: ConversationID, AccessRequest)
    /// An admin answered it: every link hears the answer, so each stops asking.
    case answered(conversationID: ConversationID, AccessRequest, AccessAnswer, by: UserID)
    case notice(conversationID: ConversationID, turnID: TurnID?, text: String)
    case noticeWithActions(
        conversationID: ConversationID,
        turnID: TurnID?,
        text: String,
        actions: [OutboundAction]
    )
    case reset(conversationID: ConversationID)
    /// Something was noted from `message` for its author's memory: it's marked so for a moment.
    case noted(conversationID: ConversationID, NotedMessage)
    /// The mark on `message` is taken off.
    case unnoted(conversationID: ConversationID, NotedMessage)
}

extension OutboundEvent {
    /// The conversation it's from.
    public var conversationID: ConversationID {
        switch self {
        case .reply(let reply): reply.conversationID
        case .asked(let conversation, _), .answered(let conversation, _, _, _), .notice(let conversation, _, _),
            .noticeWithActions(let conversation, _, _, _), .reset(let conversation), .noted(let conversation, _),
            .unnoted(let conversation, _):
            conversation
        }
    }
}

public enum ConversationEffect: Hashable, Codable, Sendable {
    case runReply(ConversationTurnRequest)
    case publish(OutboundEvent)
    case cancelModel(TurnID)
}

public enum ConversationAction: Sendable {
    case receive(
        message: InboundMessage,
        turnID: TurnID,
        agentRole: String
    )
    /// The turn running now needed what its scope didn't allow, which its space's admins are asked
    /// for, as `id`.
    case awaiting(AccessRequestID)
    /// An admin answered `request`: the turn that waited for it continues, as `turnID`, with the
    /// answer, on behalf of whoever asked.
    case answered(AccessRequest, AccessAnswer, turnID: TurnID, at: Date)
    case modelCompleted(turnID: TurnID, completion: ConversationCompletion)
    case replyDelivered(turnID: TurnID)
    case modelFailed(turnID: TurnID, failure: ConversationFailure)
    case reset
    case resume
}

// MARK: Deciding

/// What an action comes to: the events it journals, in order, and what's done once they are.
public struct ConversationDecision: Equatable, Sendable {
    public let events: [ConversationEvent]
    public let effects: [ConversationEffect]

    public init(events: [ConversationEvent] = [], effects: [ConversationEffect] = []) {
        self.events = events
        self.effects = effects
    }
}

extension ConversationDecision {
    /// What `action` comes to in `state`. Only applying its events changes the conversation.
    public init(_ action: ConversationAction, in state: ConversationState) {
        self = Self.deciding(action, in: state)
    }

    private static func deciding(_ action: ConversationAction, in state: ConversationState) -> ConversationDecision {
        switch action {
        case .receive(let message, let turnID, let agentRole):
            guard message.conversationID == state.conversationID,
                !state.inbox.acceptedMessageIDs.contains(message.id)
            else { return ConversationDecision() }
            let text = message.text.trimmed()
            guard !text.isEmpty || !message.attachments.isEmpty else {
                // Input rejection, not a turn failure: a `nil` turn ID means no turn ended, even
                // when another turn is running.
                return ConversationDecision(effects: [
                    .publish(
                        .reply(
                            .failed(
                                conversationID: state.conversationID, turnID: nil, message: "Message cannot be empty."))
                    )
                ])
            }
            let pending = PendingConversationMessage(
                message: InboundMessage(
                    id: message.id, conversationID: message.conversationID, participantID: message.participantID,
                    userID: message.userID, author: message.author, text: text, attachments: message.attachments,
                    receivedAt: message.receivedAt),
                turnID: turnID, agentRole: agentRole)
            var events: [ConversationEvent] = []
            guard case .running = state.inbox.status else {
                // Idle, or failed: the oldest waiting message starts, which is this one if none waits.
                let next = state.inbox.pendingMessages.first ?? pending
                if next != pending { events.append(.inbox(.queued(pending))) }
                return ConversationDecision(
                    events: events + [.inbox(.turnStarted(next))],
                    effects: [.runReply(ConversationTurnRequest(next, in: state))])
            }
            return ConversationDecision(events: events + [.inbox(.queued(pending))])

        case .awaiting(let id):
            guard let active = state.inbox.activeMessage, state.awaiting[id] == nil else {
                return ConversationDecision()
            }
            return ConversationDecision(events: [.awaiting(id, active)])

        case .answered(let request, let answer, let turnID, let at):
            guard let waited = state.awaiting[request.id] else { return ConversationDecision() }
            // The turn that waited continues: its asker is told the answer, as their next message.
            let told = InboundMessage(
                id: MessageID(rawValue: request.id.rawValue), conversationID: state.conversationID,
                participantID: waited.message.participantID, userID: waited.message.userID,
                author: waited.message.author, text: answer.said(about: request.request), receivedAt: at)
            let answered = ConversationEvent.answered(request.id)
            let continued = Self.deciding(
                .receive(message: told, turnID: turnID, agentRole: waited.agentRole),
                in: state.applying([answered]))
            return ConversationDecision(events: [answered] + continued.events, effects: continued.effects)

        case .modelCompleted(let turnID, let completion):
            guard state.inbox.activeTurnID == turnID else { return ConversationDecision() }
            var events: [ConversationEvent] = []
            var effects: [ConversationEffect] = []
            switch completion {
            case .reply(let reply):
                events.append(.replyQueued(PendingConversationReply(turnID: turnID, reply: reply)))
            case .void:
                effects.append(.publish(.reply(.completed(conversationID: state.conversationID, turnID: turnID))))
            }
            events.append(.inbox(.turnCompleted(turnID)))
            let next = startingNext(in: state)
            return ConversationDecision(events: events + next.events, effects: effects + next.effects)

        case .replyDelivered(let turnID):
            guard state.pendingReplies.contains(where: { $0.turnID == turnID }) else { return ConversationDecision() }
            return ConversationDecision(events: [.replyDelivered(turnID)])

        case .modelFailed(let turnID, let failure):
            guard state.inbox.activeTurnID == turnID else { return ConversationDecision() }
            // A message already waiting is the person's next word: it starts now, as after a reply.
            let next = startingNext(in: state)
            return ConversationDecision(
                events: [.inbox(.turnFailed(turnID, failure))] + next.events, effects: next.effects)

        case .reset:
            let cancel = state.inbox.activeTurnID.map { [ConversationEffect.cancelModel($0)] } ?? []
            return ConversationDecision(
                events: [.reset], effects: cancel + [.publish(.reset(conversationID: state.conversationID))])

        case .resume:
            switch state.inbox.status {
            case .idle:
                return startingNext(in: state)
            case .running:
                guard let active = state.inbox.activeMessage else { return ConversationDecision() }
                return ConversationDecision(effects: [
                    .runReply(ConversationTurnRequest(active, in: state))
                ])
            case .failed:
                return startingNext(in: state)
            }
        }
    }

    /// The oldest waiting message's turn starting, if one waits.
    private static func startingNext(in state: ConversationState) -> ConversationDecision {
        guard let next = state.inbox.pendingMessages.first else { return ConversationDecision() }
        return ConversationDecision(
            events: [.inbox(.turnStarted(next))],
            effects: [.runReply(ConversationTurnRequest(next, in: state))])
    }
}

extension ConversationState {
    /// The conversation after `events`, in order.
    public func applying(_ events: [ConversationEvent]) -> ConversationState {
        var next = self
        for event in events { next.apply(event) }
        return next
    }
}
