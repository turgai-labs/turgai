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
        ParticipantID(channel: channel, rawValue: externalAddress.rawValue)
    }
}

/// Stable event-store identity for a conversation.
///
/// The raw string is used only at the EventSourcing boundary. Keeping the
/// conversation identity alongside it prevents callers from passing an
/// arbitrary journal ID or duplicating the prefix/parsing rules.
public struct ConversationPersistenceID: RawRepresentable, Hashable, Codable, Sendable {
    public static let prefix = "norby-conversation-"

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

/// A transient input delivered to a live Norby session.
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
    case command(ConversationCommand)
}

public struct PendingConversationMessage: Hashable, Codable, Sendable {
    public let message: InboundMessage
    public let turnID: TurnID

    public init(message: InboundMessage, turnID: TurnID) {
        self.message = message
        self.turnID = turnID
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

/// Legacy journal payload retained only so conversations written before
/// compaction-owned memory extraction can still replay. New conversations do
/// not enqueue or process this value.
public struct PendingMemoryObservation: Hashable, Codable, Sendable {
    public let turnID: TurnID
    public let message: InboundMessage
    public let response: String?

    public init(
        turnID: TurnID,
        message: InboundMessage,
        response: String?
    ) {
        self.turnID = turnID
        self.message = message
        self.response = response
    }
}

public enum ConversationEvent: Codable, Sendable, Equatable {
    case messageQueued(PendingConversationMessage)
    case replyQueued(PendingConversationReply)
    case replyDelivered(TurnID)
    case turnStarted(PendingConversationMessage)
    case turnCompleted(TurnID)
    case turnFailed(TurnID, ConversationFailure)
    // Replay-only legacy events. The current reducer ignores them; compaction
    // will obtain extraction input from the durable model transcript instead.
    case memoryObservationQueued(PendingMemoryObservation)
    case memoryObservationsCompleted([TurnID])
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

public struct ConversationState: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    public internal(set) var status: ConversationStatus
    public internal(set) var acceptedMessageIDs: [MessageID]
    public internal(set) var pendingMessages: [PendingConversationMessage]
    public internal(set) var pendingReplies: [PendingConversationReply]
    public internal(set) var activeMessage: PendingConversationMessage?
    public init(
        conversationID: ConversationID,
        status: ConversationStatus = .idle,
        acceptedMessageIDs: [MessageID] = [],
        pendingMessages: [PendingConversationMessage] = [],
        pendingReplies: [PendingConversationReply] = [],
        activeMessage: PendingConversationMessage? = nil
    ) {
        self.conversationID = conversationID
        self.status = status
        self.acceptedMessageIDs = acceptedMessageIDs
        self.pendingMessages = pendingMessages
        self.pendingReplies = pendingReplies
        self.activeMessage = activeMessage
    }

    public var activeTurnID: TurnID? {
        guard case .running(let turnID) = status else { return nil }
        return turnID
    }

    public mutating func apply(_ event: ConversationEvent) {
        switch event {
        case .messageQueued(let pending):
            rememberAcceptedMessage(pending.message.id)
            pendingMessages.append(pending)

        case .replyQueued(let pending):
            if !pendingReplies.contains(pending) {
                pendingReplies.append(pending)
            }
            // Queueing the terminal reply is the durable completion barrier.
            // It is deliberately applied before turnCompleted is emitted so
            // a crash between journal writes cannot lose the reply.
            if activeTurnID == pending.turnID {
                activeMessage = nil
                status = .idle
            }

        case .replyDelivered(let turnID):
            pendingReplies.removeAll { $0.turnID == turnID }

        case .turnStarted(let pending):
            rememberAcceptedMessage(pending.message.id)
            if let index = pendingMessages.firstIndex(where: { $0.turnID == pending.turnID }) {
                pendingMessages.remove(at: index)
            }
            activeMessage = pending
            status = .running(pending.turnID)

        case .turnCompleted(let turnID):
            guard activeTurnID == turnID else { return }
            activeMessage = nil
            status = .idle

        case .turnFailed(let turnID, let failure):
            guard activeTurnID == turnID else { return }
            activeMessage = nil
            status = .failed(failure)

        case .memoryObservationQueued, .memoryObservationsCompleted:
            break

        case .reset:
            activeMessage = nil
            pendingMessages.removeAll(keepingCapacity: true)
            pendingReplies.removeAll(keepingCapacity: true)
            status = .idle
        }
    }

    public var requiresRecovery: Bool {
        switch status {
        case .running:
            true
        case .idle, .failed:
            !pendingMessages.isEmpty
                || !pendingReplies.isEmpty
        }
    }

    private mutating func rememberAcceptedMessage(_ messageID: MessageID) {
        guard !acceptedMessageIDs.contains(messageID) else { return }
        acceptedMessageIDs.append(messageID)
        if acceptedMessageIDs.count > 256 {
            acceptedMessageIDs.removeFirst(acceptedMessageIDs.count - 256)
        }
    }
}

public struct ConversationTurnRequest: Hashable, Codable, Sendable {
    public let conversationID: ConversationID
    public let turnID: TurnID
    public let message: InboundMessage

    public init(
        conversationID: ConversationID,
        turnID: TurnID,
        message: InboundMessage
    ) {
        self.conversationID = conversationID
        self.turnID = turnID
        self.message = message
    }
}

public enum ReplyPhase: String, Hashable, Codable, Sendable {
    case thinking
    case typing
}

public enum ReplyEvent: Hashable, Codable, Sendable {
    case started(conversationID: ConversationID, turnID: TurnID)
    case phase(conversationID: ConversationID, turnID: TurnID, phase: ReplyPhase)
    case partial(conversationID: ConversationID, turnID: TurnID, text: String)
    case keepAlive(conversationID: ConversationID, turnID: TurnID, phase: ReplyPhase)
    case finished(conversationID: ConversationID, turnID: TurnID, text: String)
    case completed(conversationID: ConversationID, turnID: TurnID)
    case failed(conversationID: ConversationID, turnID: TurnID?, message: String)
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
        turnID: TurnID
    )
    case modelCompleted(turnID: TurnID, completion: ConversationCompletion)
    case replyDelivered(turnID: TurnID)
    case modelFailed(turnID: TurnID, failure: ConversationFailure)
    case reset
    case clearFailure
    case resume
}

public func reduce(
    _ state: ConversationState,
    _ action: ConversationAction
) -> (ConversationState, [ConversationEffect]) {
    var next = state
    var effects: [ConversationEffect] = []

    switch action {
    case .receive(let message, let turnID):
        guard message.conversationID == state.conversationID else {
            return (state, [])
        }

        guard !state.acceptedMessageIDs.contains(message.id) else {
            return (state, [])
        }

        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !message.attachments.isEmpty else {
            // Input rejection, not a turn failure: a `nil` turn ID means no
            // turn ended, even when another turn is currently running.
            return (
                state,
                [
                    .publish(
                        .reply(
                            .failed(
                                conversationID: state.conversationID,
                                turnID: nil,
                                message: "Message cannot be empty."
                            )
                        )
                    )
                ]
            )
        }

        let normalizedMessage = InboundMessage(
            id: message.id,
            conversationID: message.conversationID,
            participantID: message.participantID,
            userID: message.userID,
            author: message.author,
            text: text,
            attachments: message.attachments,
            receivedAt: message.receivedAt
        )

        next.acceptedMessageIDs.append(message.id)
        if next.acceptedMessageIDs.count > 256 {
            next.acceptedMessageIDs.removeFirst(
                next.acceptedMessageIDs.count - 256
            )
        }

        switch next.status {
        case .running:
            next.pendingMessages.append(
                PendingConversationMessage(
                    message: normalizedMessage,
                    turnID: turnID
                )
            )

        case .idle, .failed:
            next.status = .idle
            next.pendingMessages.append(
                PendingConversationMessage(
                    message: normalizedMessage,
                    turnID: turnID
                )
            )
            effects += startNextTurn(&next)
        }

    case .modelCompleted(let turnID, let completion):
        guard isActive(turnID, in: next.status) else {
            return (state, [])
        }

        if case .reply(let reply) = completion {
            next.pendingReplies.append(
                PendingConversationReply(turnID: turnID, reply: reply)
            )
        }
        next.activeMessage = nil
        next.status = .idle
        if case .void = completion {
            effects.append(
                .publish(
                    .reply(
                        .completed(
                            conversationID: next.conversationID,
                            turnID: turnID
                        )
                    )
                )
            )
        }
        effects += startNextTurn(&next)

    case .replyDelivered(let turnID):
        guard next.pendingReplies.contains(where: { $0.turnID == turnID }) else {
            return (state, [])
        }
        next.pendingReplies.removeAll { $0.turnID == turnID }

    case .modelFailed(let turnID, let failure):
        guard isActive(turnID, in: next.status) else {
            return (state, [])
        }

        next.status = .failed(failure)
        next.activeMessage = nil

    case .reset:
        if let turnID = activeTurnID(in: next.status) {
            effects.append(.cancelModel(turnID))
        }
        next.status = .idle
        next.pendingMessages.removeAll(keepingCapacity: true)
        next.pendingReplies.removeAll(keepingCapacity: true)
        next.activeMessage = nil
        effects.append(.publish(.reset(conversationID: next.conversationID)))

    case .clearFailure:
        guard case .failed = next.status else {
            return (state, [])
        }
        next.status = .idle
        effects += startNextTurn(&next)

    case .resume:
        switch next.status {
        case .idle:
            effects += startNextTurn(&next)
        case .running:
            guard let activeMessage = next.activeMessage else {
                return (state, [])
            }
            effects.append(
                .runReply(
                    modelRequest(
                        for: activeMessage,
                        conversationID: next.conversationID
                    )
                )
            )
        case .failed:
            guard !next.pendingMessages.isEmpty else {
                return (state, [])
            }
            next.status = .idle
            effects += startNextTurn(&next)
        }
    }

    guard next != state || !effects.isEmpty else {
        return (state, effects)
    }

    return (next, effects)
}

private func startNextTurn(_ state: inout ConversationState) -> [ConversationEffect] {
    guard !state.pendingMessages.isEmpty else {
        return []
    }

    let pending = state.pendingMessages.removeFirst()
    let turnID = pending.turnID
    state.activeMessage = pending
    state.status = .running(turnID)

    return [
        .runReply(
            modelRequest(
                for: pending,
                conversationID: state.conversationID
            )
        )
    ]
}

private func modelRequest(
    for pending: PendingConversationMessage,
    conversationID: ConversationID
) -> ConversationTurnRequest {
    return ConversationTurnRequest(
        conversationID: conversationID,
        turnID: pending.turnID,
        message: pending.message
    )
}

private func activeTurnID(in status: ConversationStatus) -> TurnID? {
    guard case .running(let turnID) = status else {
        return nil
    }
    return turnID
}

private func isActive(_ turnID: TurnID, in status: ConversationStatus) -> Bool {
    activeTurnID(in: status) == turnID
}

private func fail(
    state: ConversationState,
    turnID: TurnID,
    failure: ConversationFailure
) -> (ConversationState, [ConversationEffect]) {
    var next = state
    next.status = .failed(failure)
    next.activeMessage = nil
    return (
        next,
        []
    )
}
