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

    /// The participant a direct user↔bot conversation belongs to. Channels
    /// address direct conversations by the participant's own identity, so the
    /// external address is that participant.
    public var participantID: ParticipantID {
        ParticipantID(
            channel: ChannelID(channel.providerName),
            rawValue: externalAddress.rawValue
        )
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

/// A durable, channel-qualified reference to attached content.
///
/// The value is intentionally opaque outside the channel adapter. For
/// example, Telegram uses its non-secret `file_id`; credentials and temporary
/// download URLs never become part of the conversation model.
public struct AttachmentID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(channel: ChannelID, externalID: String) {
        self.rawValue = "\(channel.rawValue):\(externalID)"
    }

    public var channel: ChannelID? {
        guard let separator = rawValue.firstIndex(of: ":"),
            separator != rawValue.startIndex
        else {
            return nil
        }
        return ChannelID(String(rawValue[..<separator]))
    }

    public var externalID: String? {
        guard let separator = rawValue.firstIndex(of: ":") else {
            return nil
        }
        let value = rawValue[rawValue.index(after: separator)...]
        return value.isEmpty ? nil : String(value)
    }
}

/// A media reference attached to a conversation message.
///
/// Messages persist only an opaque reference and descriptive metadata. The
/// channel adapter resolves the reference if an agent explicitly fetches it;
/// neither credentials, temporary URLs, nor bytes are persisted here.
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct InboundMessage: Hashable, Codable, Sendable {
    public let id: MessageID
    public let conversationID: ConversationID
    public let participantID: ParticipantID
    public let userID: UserID
    public let author: MessageAuthor?
    public let text: String
    public let attachments: [Attachment]
    public let receivedAt: Date

    public init(
        id: MessageID = MessageID(),
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID? = nil,
        author: MessageAuthor? = nil,
        text: String,
        attachments: [Attachment] = [],
        receivedAt: Date
    ) {
        self.id = id
        self.conversationID = conversationID
        self.participantID = participantID
        self.userID = userID ?? UserID(participantID: participantID)
        self.author = author?.isEmpty == true ? nil : author
        self.text = text
        self.attachments = attachments
        self.receivedAt = receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case conversationID
        case participantID
        case userID
        case author
        case text
        case attachments
        case receivedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(MessageID.self, forKey: .id)
        self.conversationID = try container.decode(ConversationID.self, forKey: .conversationID)
        self.participantID = try container.decode(ParticipantID.self, forKey: .participantID)
        self.userID =
            try container.decodeIfPresent(UserID.self, forKey: .userID)
            ?? UserID(participantID: participantID)
        self.author = try container.decodeIfPresent(MessageAuthor.self, forKey: .author)
        self.text = try container.decode(String.self, forKey: .text)
        self.attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        self.receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(participantID, forKey: .participantID)
        try container.encode(userID, forKey: .userID)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(text, forKey: .text)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(receivedAt, forKey: .receivedAt)
    }
}

/// A transient input delivered to a live Turgai session.
///
/// Channel adapters translate their provider-specific updates into this
/// value before they enter the application connection layer.
public enum ConversationCommand: Sendable, Equatable {
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
}

public enum ConversationInput: Sendable, Equatable {
    case message(
        InboundMessage,
        turnID: TurnID
    )
    case connect(ConversationID)
    case reset(ConversationID)
    case approval(conversationID: ConversationID, approvalID: UUID, decision: ApprovalDecision, by: UserID)
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
    /// Who the conversation's admins are now, as its platform says.
    case admins(conversationID: ConversationID, Set<UserID>)
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
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
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

public enum ConversationEvent: Codable, Sendable, Equatable {
    /// Someone became one of its members.
    case member(GroupEvent)
    /// Its agent's inbox: a message waiting, or a turn starting or ending.
    case inbox(AgentInboxEvent)
    case replyQueued(PendingConversationReply)
    case replyDelivered(TurnID)
    case reset
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

    public init(id: String, role: ConversationHistoryRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
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
    /// The people in it: whoever writes joins, the first as its admin.
    public internal(set) var members: Group
    /// Its agent's inbox.
    public internal(set) var inbox: AgentInbox
    public internal(set) var pendingReplies: [PendingConversationReply]
    public internal(set) var history: [ConversationHistoryEntry]

    public init(
        conversationID: ConversationID,
        members: Group = Group(),
        inbox: AgentInbox = AgentInbox(),
        pendingReplies: [PendingConversationReply] = [],
        history: [ConversationHistoryEntry] = []
    ) {
        self.conversationID = conversationID
        self.members = members
        self.inbox = inbox
        self.pendingReplies = pendingReplies
        self.history = history
    }

    public mutating func apply(_ event: ConversationEvent) {
        switch event {
        case .member(let event):
            members = members.applying(event)

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
            inbox = inbox.answered(pending.turnID)
            appendHistory(
                ConversationHistoryEntry(
                    id: "reply:\(pending.turnID.rawValue.uuidString)",
                    role: .assistant,
                    text: pending.text
                )
            )

        case .replyDelivered(let turnID):
            pendingReplies.removeAll { $0.turnID == turnID }

        case .reset:
            inbox = inbox.emptied()
            pendingReplies.removeAll(keepingCapacity: true)
            history.removeAll(keepingCapacity: true)
        }
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
                text: message.text
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
    /// The turn that answers `pending` in the conversation with `conversationID`.
    init(_ pending: PendingConversationMessage, in conversationID: ConversationID) {
        self.init(
            conversationID: conversationID, turnID: pending.turnID, message: pending.message,
            agentRole: pending.agentRole)
    }
}

public enum ReplyPhase: String, Hashable, Codable, Sendable {
    case thinking
    case typing
}

public enum ReplyEvent: Hashable, Codable, Sendable {
    case userMessage(
        conversationID: ConversationID,
        turnID: TurnID,
        messageID: MessageID,
        text: String
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

public enum ApprovalDecision: Hashable, Codable, Sendable {
    case granted
    case denied
}

/// A question to the user before an action runs, asked in the conversation that
/// wants it. It's answered by its ID.
public struct ApprovalPrompt: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    /// What would run, such as `Music.play`.
    public let action: String
    /// Its arguments, as the user should read them.
    public let arguments: String

    public init(id: UUID, action: String, arguments: String) {
        self.id = id
        self.action = action
        self.arguments = arguments
    }
}

public enum OutboundEvent: Hashable, Codable, Sendable {
    case reply(ReplyEvent)
    case approvalRequested(conversationID: ConversationID, turnID: TurnID?, prompt: ApprovalPrompt)
    /// Every connection hears the answer, so each can stop asking.
    case approvalResolved(conversationID: ConversationID, approvalID: UUID, decision: ApprovalDecision)
    case notice(conversationID: ConversationID, turnID: TurnID?, text: String)
    case noticeWithActions(
        conversationID: ConversationID,
        turnID: TurnID?,
        text: String,
        actions: [OutboundAction]
    )
    case reset(conversationID: ConversationID)
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
    case modelCompleted(turnID: TurnID, completion: ConversationCompletion)
    case replyDelivered(turnID: TurnID)
    case modelFailed(turnID: TurnID, failure: ConversationFailure)
    case reset
    case resume
    /// Who its admins are now, as its platform says.
    case admins(Set<UserID>)
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
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Whoever writes is one of its members.
            var events = state.members.admitting(message.userID).map { [ConversationEvent.member($0)] } ?? []
            guard case .running = state.inbox.status else {
                // Idle, or failed: the oldest waiting message starts, which is this one if none waits.
                let next = state.inbox.pendingMessages.first ?? pending
                if next != pending { events.append(.inbox(.queued(pending))) }
                return ConversationDecision(
                    events: events + [.inbox(.turnStarted(next))],
                    effects: [.runReply(ConversationTurnRequest(next, in: state.conversationID))])
            }
            return ConversationDecision(events: events + [.inbox(.queued(pending))])

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

        case .admins(let admins):
            return ConversationDecision(events: state.members.having(admins: admins).map(ConversationEvent.member))

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
                    .runReply(ConversationTurnRequest(active, in: state.conversationID))
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
            effects: [.runReply(ConversationTurnRequest(next, in: state.conversationID))])
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
