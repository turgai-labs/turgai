import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public struct TelegramUser: Codable, Equatable, Sendable {
    public let id: Int64
    public let isBot: Bool
    public let firstName: String
    public let lastName: String?
    public let username: String?

    public init(
        id: Int64,
        isBot: Bool = false,
        firstName: String = "",
        lastName: String? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.isBot = isBot
        self.firstName = firstName
        self.lastName = lastName
        self.username = username
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case firstName = "first_name"
        case lastName = "last_name"
        case username
    }
}

public struct TelegramChat: Codable, Equatable, Sendable {
    public let id: Int64
    public let type: String
    public let title: String?
    public let username: String?

    public init(
        id: Int64,
        type: String = "private",
        title: String? = nil,
        username: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.username = username
    }
}

public struct TelegramPhotoSize: Codable, Equatable, Sendable {
    public let fileID: String
    public let fileUniqueID: String
    public let width: Int
    public let height: Int
    public let fileSize: Int64?

    public init(
        fileID: String,
        fileUniqueID: String,
        width: Int,
        height: Int,
        fileSize: Int64? = nil
    ) {
        self.fileID = fileID
        self.fileUniqueID = fileUniqueID
        self.width = width
        self.height = height
        self.fileSize = fileSize
    }

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case width
        case height
        case fileSize = "file_size"
    }
}

public struct TelegramDocument: Codable, Equatable, Sendable {
    public let fileID: String
    public let fileUniqueID: String
    public let filename: String?
    public let mimeType: String?
    public let fileSize: Int64?

    public init(
        fileID: String,
        fileUniqueID: String,
        filename: String? = nil,
        mimeType: String? = nil,
        fileSize: Int64? = nil
    ) {
        self.fileID = fileID
        self.fileUniqueID = fileUniqueID
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
    }

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case filename = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

public struct TelegramMessage: Codable, Equatable, Sendable {
    public let messageID: Int64
    public let from: TelegramUser?
    public let chat: TelegramChat
    public let date: Int64
    public let text: String?
    public let caption: String?
    public let photo: [TelegramPhotoSize]?
    public let document: TelegramDocument?

    public init(
        messageID: Int64,
        from: TelegramUser?,
        chat: TelegramChat,
        date: Int64,
        text: String?,
        caption: String? = nil,
        photo: [TelegramPhotoSize]? = nil,
        document: TelegramDocument? = nil
    ) {
        self.messageID = messageID
        self.from = from
        self.chat = chat
        self.date = date
        self.text = text
        self.caption = caption
        self.photo = photo
        self.document = document
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case date
        case text
        case caption
        case photo
        case document
    }
}

public struct TelegramCallbackQuery: Codable, Equatable, Sendable {
    public let id: String
    public let from: TelegramUser
    public let message: TelegramMessage?
    public let data: String?

    public init(
        id: String,
        from: TelegramUser,
        message: TelegramMessage? = nil,
        data: String? = nil
    ) {
        self.id = id
        self.from = from
        self.message = message
        self.data = data
    }
}

public struct TelegramUpdate: Codable, Equatable, Sendable {
    public let updateID: Int64
    public let message: TelegramMessage?
    public let callbackQuery: TelegramCallbackQuery?

    public init(
        updateID: Int64,
        message: TelegramMessage? = nil,
        callbackQuery: TelegramCallbackQuery? = nil
    ) {
        self.updateID = updateID
        self.message = message
        self.callbackQuery = callbackQuery
    }

    private enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

public enum TelegramCommand: String, Sendable, Equatable {
    case start
    case reset
    case memory
    case forget
    case context
    case diagnose
    case reminders
    case tasks
    case pauseTask = "pause-task"
    case unpauseTask = "unpause-task"
    case cancelTask = "cancel-task"
    case cancelReminder = "cancel-reminder"
}

public enum TelegramInboundEvent: Equatable, Sendable {
    case message(
        InboundMessage,
        telegramMessageID: Int64,
        turnID: TurnID,
        supportsDrafts: Bool
    )
    case start(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
    case reset(
        conversationID: ConversationID,
        participantID: ParticipantID,
        userID: UserID
    )
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
}

public enum TelegramPublisherError: Error, Equatable, Sendable {
    case invalidConversation(ConversationID)
}

/// Transport limits for Telegram's streaming and activity endpoints.
///
/// These limits live in the Telegram adapter. They are deliberately not part
/// of Hail's turn model: the connection coalesces replaceable previews while
/// this boundary decides how quickly Telegram can receive updates.
public struct TelegramDeliveryConfiguration: Sendable, Equatable {
    public let minimumDraftInterval: Duration
    public let minimumTypingActionInterval: Duration
    public let fallbackRateLimitDelay: Duration
    public let maximumRateLimitRetries: Int

    public init(
        minimumDraftInterval: Duration = .seconds(1),
        minimumTypingActionInterval: Duration = .seconds(4),
        fallbackRateLimitDelay: Duration = .seconds(1),
        maximumRateLimitRetries: Int = 3
    ) {
        self.minimumDraftInterval = max(.zero, minimumDraftInterval)
        self.minimumTypingActionInterval = max(.zero, minimumTypingActionInterval)
        self.fallbackRateLimitDelay = max(.zero, fallbackRateLimitDelay)
        self.maximumRateLimitRetries = max(0, maximumRateLimitRetries)
    }
}

/// Interprets the scoped reply lifecycle as Telegram actions.
public actor TelegramEventPublisher {
    private struct DraftKey: Hashable, Sendable {
        let conversationID: ConversationID
        let turnID: TurnID
    }

    private let client: TelegramAPIClient
    private let maximumTextLength: Int
    private let delivery: TelegramDeliveryConfiguration
    private let clock = ContinuousClock()
    private var sourceMessageIDs: [ConversationID: [TurnID: Int64]] = [:]
    private var draftIDs: [ConversationID: [TurnID: Int64]] = [:]
    private var draftEnabledConversations: Set<ConversationID> = []
    private var lastSentDraftText: [DraftKey: String] = [:]
    private var lastTypingActionReservation: [ConversationID: ContinuousClock.Instant] = [:]
    private var nextDraftID: Int64 = 1
    private static let deliveryBackoff: [Duration] = [.seconds(1), .seconds(2)]

    public init(
        client: TelegramAPIClient,
        maximumTextLength: Int = 4_096,
        delivery: TelegramDeliveryConfiguration = TelegramDeliveryConfiguration()
    ) {
        self.client = client
        self.maximumTextLength = max(1, maximumTextLength)
        self.delivery = delivery
    }

    public func publish(_ event: OutboundEvent) async throws {
        switch event {
        case .reply(let reply):
            switch reply {
            case .userMessage:
                break
            case .started(let conversationID, let turnID):
                await setReaction(
                    .thinking,
                    conversationID: conversationID,
                    turnID: turnID
                )
                try await sendTypingAction(for: conversationID)

            case .phase(let conversationID, let turnID, let phase):
                switch phase {
                case .thinking:
                    await setReaction(
                        .thinking,
                        conversationID: conversationID,
                        turnID: turnID
                    )
                    try await sendTypingAction(for: conversationID)
                case .typing:
                    await setReaction(
                        .typing,
                        conversationID: conversationID,
                        turnID: turnID
                    )
                    try await sendTypingAction(for: conversationID)
                }

            case .partial(let conversationID, let turnID, let text):
                guard draftEnabledConversations.contains(conversationID) else {
                    return
                }
                let chatID = try chatID(for: conversationID)
                let html = TelegramHTMLFormatter.streamingFirstChunk(
                    markdown: text,
                    maximumLength: maximumTextLength
                )
                guard !html.isEmpty else { return }
                let key = DraftKey(conversationID: conversationID, turnID: turnID)
                guard lastSentDraftText[key] != html else { return }
                let draftID = draftID(for: conversationID, turnID: turnID)
                try await client.sendMessageDraft(chatID, draftID, html, .html)
                lastSentDraftText[key] = html

            case .keepAlive(let conversationID, let turnID, let phase):
                guard phase == .thinking || phase == .typing else { return }
                if draftEnabledConversations.contains(conversationID),
                    let html = lastSentDraftText[
                        DraftKey(conversationID: conversationID, turnID: turnID)
                    ]
                {
                    let chatID = try chatID(for: conversationID)
                    let draftID = draftID(for: conversationID, turnID: turnID)
                    // Telegram drafts are ephemeral. Refresh the current
                    // draft during a long model/tool round so the user keeps
                    // seeing the latest visible text until the final message
                    // is sent.
                    try? await client.sendMessageDraft(
                        chatID,
                        draftID,
                        html,
                        .html
                    )
                }
                try await sendTypingAction(for: conversationID)

            case .status(let conversationID, _, _):
                try await sendTypingAction(for: conversationID)

            case .finished(let conversationID, let turnID, let text):
                let chatID = try chatID(for: conversationID)
                let replyTo = replyParameters(
                    conversationID: conversationID,
                    turnID: turnID
                )
                await setReaction(
                    nil,
                    conversationID: conversationID,
                    turnID: turnID
                )
                for chunk in TelegramHTMLFormatter.chunks(
                    markdown: text,
                    maximumLength: maximumTextLength
                ) {
                    _ = try await sendMessage(
                        text: chunk,
                        chatID: chatID,
                        replyParameters: replyTo
                    )
                }
                sourceMessageIDs[conversationID]?[turnID] = nil
                draftIDs[conversationID]?[turnID] = nil
                lastSentDraftText[DraftKey(conversationID: conversationID, turnID: turnID)] = nil

            case .completed(let conversationID, let turnID):
                _ = try chatID(for: conversationID)
                await setReaction(
                    nil,
                    conversationID: conversationID,
                    turnID: turnID
                )
                sourceMessageIDs[conversationID]?[turnID] = nil
                draftIDs[conversationID]?[turnID] = nil
                lastSentDraftText[DraftKey(conversationID: conversationID, turnID: turnID)] = nil

            case .failed(let conversationID, let turnID, let text):
                let chatID = try chatID(for: conversationID)
                let replyTo = replyParameters(
                    conversationID: conversationID,
                    turnID: turnID
                )
                if let turnID {
                    await setReaction(
                        nil,
                        conversationID: conversationID,
                        turnID: turnID
                    )
                }
                for chunk in TelegramHTMLFormatter.chunks(
                    markdown: text,
                    maximumLength: maximumTextLength
                ) {
                    _ = try await sendMessage(
                        text: chunk,
                        chatID: chatID,
                        replyParameters: replyTo
                    )
                }
                if let turnID {
                    sourceMessageIDs[conversationID]?[turnID] = nil
                    draftIDs[conversationID]?[turnID] = nil
                    lastSentDraftText[DraftKey(conversationID: conversationID, turnID: turnID)] = nil
                }
            }

        case .notice(let conversationID, let turnID, let text):
            let chatID = try chatID(for: conversationID)
            let replyTo = replyParameters(
                conversationID: conversationID,
                turnID: turnID
            )
            for chunk in TelegramHTMLFormatter.chunks(
                markdown: text,
                maximumLength: maximumTextLength
            ) {
                _ = try await sendMessage(
                    text: chunk,
                    chatID: chatID,
                    replyParameters: replyTo
                )
            }

        case .noticeWithActions(let conversationID, let turnID, let text, let actions):
            let chatID = try chatID(for: conversationID)
            let replyTo = replyParameters(
                conversationID: conversationID,
                turnID: turnID
            )
            let chunks = TelegramHTMLFormatter.chunks(
                markdown: text,
                maximumLength: maximumTextLength
            )
            let markup = TelegramInlineKeyboardMarkup(
                inlineKeyboard: actions.map { action in
                    [TelegramInlineKeyboardButton(text: action.label, callbackData: action.command)]
                }
            )
            for (index, chunk) in chunks.enumerated() {
                _ = try await client.sendMessageWithMarkup(
                    chatID,
                    chunk,
                    .html,
                    replyTo,
                    index == chunks.index(before: chunks.endIndex) ? markup : nil
                )
            }

        case .reset(let conversationID):
            sourceMessageIDs[conversationID] = nil
            draftIDs[conversationID] = nil
            draftEnabledConversations.remove(conversationID)
            lastSentDraftText = lastSentDraftText.filter {
                $0.key.conversationID != conversationID
            }
            lastTypingActionReservation[conversationID] = nil
        }
    }

    public func setDraftsEnabled(
        _ enabled: Bool,
        for conversationID: ConversationID
    ) {
        if enabled {
            draftEnabledConversations.insert(conversationID)
        } else {
            draftEnabledConversations.remove(conversationID)
        }
    }

    /// Records the Telegram message that started a turn so the terminal reply
    /// can use Telegram's native reply relationship.
    public func markSeen(
        conversationID: ConversationID,
        telegramMessageID: Int64,
        turnID: TurnID
    ) async throws {
        sourceMessageIDs[conversationID, default: [:]][turnID] = telegramMessageID
        let chatID = try chatID(for: conversationID)
        try await client.setMessageReaction(chatID, telegramMessageID, .seen)
    }

    /// Sends a standalone message outside any model turn (greetings, status
    /// replies, and other host-originated text).
    public func sendText(conversationID: ConversationID, text: String) async throws {
        let chatID = try chatID(for: conversationID)
        for chunk in TelegramHTMLFormatter.chunks(
            markdown: text,
            maximumLength: maximumTextLength
        ) {
            _ = try await sendMessage(
                text: chunk,
                chatID: chatID,
                replyParameters: nil
            )
        }
    }

    private func sendMessage(
        text: String,
        chatID: Int64,
        replyParameters: TelegramReplyParameters?,
        backoff: ArraySlice<Duration> = TelegramEventPublisher.deliveryBackoff[...],
        rateLimitRetriesRemaining: Int? = nil
    ) async throws -> TelegramMessage {
        let rateLimitRetriesRemaining =
            rateLimitRetriesRemaining
            ?? delivery.maximumRateLimitRetries

        do {
            return try await client.sendMessage(
                chatID,
                text,
                .html,
                replyParameters
            )
        } catch let error as TelegramAPIError {
            if case .rateLimited(let retryAfter) = error {
                guard rateLimitRetriesRemaining > 0 else {
                    throw error
                }

                try await Task.sleep(
                    for: retryAfter ?? delivery.fallbackRateLimitDelay
                )
                try Task.checkCancellation()
                return try await sendMessage(
                    text: text,
                    chatID: chatID,
                    replyParameters: replyParameters,
                    backoff: backoff,
                    rateLimitRetriesRemaining: rateLimitRetriesRemaining - 1
                )
            }

            guard let delay = backoff.first else { throw error }
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            return try await sendMessage(
                text: text,
                chatID: chatID,
                replyParameters: replyParameters,
                backoff: backoff.dropFirst(),
                rateLimitRetriesRemaining: rateLimitRetriesRemaining
            )
        } catch {
            guard let delay = backoff.first else { throw error }
            try await Task.sleep(for: delay)
            try Task.checkCancellation()
            return try await sendMessage(
                text: text,
                chatID: chatID,
                replyParameters: replyParameters,
                backoff: backoff.dropFirst(),
                rateLimitRetriesRemaining: rateLimitRetriesRemaining
            )
        }
    }

    private func chatID(for conversationID: ConversationID) throws -> Int64 {
        guard conversationID.channel.providerName == "telegram",
            let chatID = Int64(conversationID.externalAddress.rawValue)
        else {
            throw TelegramPublisherError.invalidConversation(conversationID)
        }
        return chatID
    }

    private func sendTypingAction(for conversationID: ConversationID) async throws {
        let chatID = try chatID(for: conversationID)
        guard reserveTypingActionSlot(for: conversationID) else {
            return
        }
        try await withRateLimitRetry { [self] in
            try await self.client.sendChatAction(chatID, "typing")
        }
    }

    private func reserveTypingActionSlot(for conversationID: ConversationID) -> Bool {
        let now = clock.now
        if let last = lastTypingActionReservation[conversationID],
            now < last.advanced(by: delivery.minimumTypingActionInterval)
        {
            return false
        }
        lastTypingActionReservation[conversationID] = now
        return true
    }

    private func withRateLimitRetry<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch let error as TelegramAPIError {
            guard case .rateLimited(let retryAfter) = error,
                delivery.maximumRateLimitRetries > 0
            else {
                throw error
            }

            return try await withRateLimitRetry(
                operation,
                remainingRetries: delivery.maximumRateLimitRetries - 1,
                retryAfter: retryAfter
            )
        }
    }

    private func withRateLimitRetry<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value,
        remainingRetries: Int,
        retryAfter: Duration?
    ) async throws -> Value {
        try await Task.sleep(
            for: retryAfter ?? delivery.fallbackRateLimitDelay
        )
        try Task.checkCancellation()

        do {
            return try await operation()
        } catch let error as TelegramAPIError {
            guard case .rateLimited(let nextRetryAfter) = error,
                remainingRetries > 0
            else {
                throw error
            }

            return try await withRateLimitRetry(
                operation,
                remainingRetries: remainingRetries - 1,
                retryAfter: nextRetryAfter
            )
        }
    }

    private func draftID(
        for conversationID: ConversationID,
        turnID: TurnID
    ) -> Int64 {
        if let draftID = draftIDs[conversationID]?[turnID] {
            return draftID
        }

        let draftID = nextDraftID
        nextDraftID = nextDraftID == Int64.max ? 1 : nextDraftID + 1
        draftIDs[conversationID, default: [:]][turnID] = draftID
        return draftID
    }

    private func replyParameters(
        conversationID: ConversationID,
        turnID: TurnID?
    ) -> TelegramReplyParameters? {
        guard let turnID,
            let messageID = sourceMessageIDs[conversationID]?[turnID]
        else {
            return nil
        }
        return TelegramReplyParameters(messageID: messageID)
    }

    private func setReaction(
        _ reaction: TelegramReaction?,
        conversationID: ConversationID,
        turnID: TurnID
    ) async {
        guard let messageID = sourceMessageIDs[conversationID]?[turnID],
            let chatID = try? chatID(for: conversationID)
        else {
            return
        }

        try? await client.setMessageReaction(chatID, messageID, reaction)
    }

}
