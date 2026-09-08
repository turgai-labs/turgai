import AsyncAlgorithms
import Logging
import NorbyApplication
import NorbyDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

/// One logical Telegram chat connection.
///
/// Telegram transports many chats over one bot-level polling loop. This is
/// the per-chat connection that the application layer attaches to a live
/// Norby session.
public actor TelegramConnection {
    public typealias InputStream = AsyncChannel<ConversationInputDelivery>

    public let id: String
    public let conversationID: ConversationID
    public let inbound: InputStream

    private let publisher: TelegramEventPublisher
    private let logger: Logger
    private var pendingReceipts: [UUID: ConversationInputReceipt] = [:]
    private var finished = false

    init(
        conversationID: ConversationID,
        publisher: TelegramEventPublisher,
        logger: Logger
    ) {
        self.id = conversationID.stableKey
        self.conversationID = conversationID
        self.publisher = publisher
        self.logger = logger
        self.inbound = InputStream()
    }

    /// Delivers one normalized Telegram update to this chat's input stream.
    func receive(_ event: TelegramInboundEvent) async -> Bool {
        guard !finished else { return false }

        switch event {
        case .message(let message, let telegramMessageID, let turnID, let capabilities):
            do {
                try await publisher.markSeen(
                    conversationID: message.conversationID,
                    telegramMessageID: telegramMessageID,
                    turnID: turnID
                )
            } catch {
                logger.warning("Telegram reaction failed: \(error)")
            }
            return await sendToApplication(
                .message(
                    message,
                    turnID: turnID,
                    capabilities: capabilities
                )
            )

        case .reset(let conversationID, _, _):
            return await sendToApplication(.reset(conversationID))

        case .memory(let conversationID, let participantID, let userID):
            return await sendToApplication(
                .memory(
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            )

        case .forget(let conversationID, let participantID, let userID):
            return await sendToApplication(
                .forget(
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            )

        case .context(let conversationID, let participantID, let userID):
            return await sendToApplication(
                .context(
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID
                )
            )

        case .start(let conversationID, _, _):
            do {
                try await publisher.sendText(
                    conversationID: conversationID,
                    text: """
                        Hi — I'm Norby, an assistant running locally on this machine. \
                        Send me a message to get started. Use /reset to clear this conversation, \
                        /memory to inspect saved memory, /context for runtime diagnostics, or /forget to clear it.
                        """
                )
            } catch {
                logger.warning("Telegram greeting failed: \(error)")
                return false
            }
            return true
        }
    }

    func connect() async -> Bool {
        await sendToApplication(.connect(conversationID))
    }

    /// Sends a channel-neutral Norby event over this Telegram chat.
    public func send(_ event: OutboundEvent) async throws {
        try await publisher.publish(event)
    }

    public func finish() async {
        guard !finished else { return }
        finished = true
        inbound.finish()
        let receipts = Array(pendingReceipts.values)
        pendingReceipts.removeAll()
        for receipt in receipts {
            await receipt.cancel()
        }
    }

    private func sendToApplication(_ input: ConversationInput) async -> Bool {
        guard !finished else { return false }

        let receipt = ConversationInputReceipt()
        let receiptID = UUID()
        pendingReceipts[receiptID] = receipt
        await inbound.send(
            ConversationInputDelivery(
                input: input,
                receipt: receipt
            )
        )
        let accepted = await receipt.wait()
        pendingReceipts[receiptID] = nil
        return accepted
    }
}

public struct TelegramBotConfiguration: Sendable {
    public let timeout: Int
    public let retryDelay: Duration
    public let delivery: TelegramDeliveryConfiguration

    public init(
        timeout: Int = 50,
        retryDelay: Duration = .seconds(1),
        delivery: TelegramDeliveryConfiguration = TelegramDeliveryConfiguration()
    ) {
        self.timeout = max(0, timeout)
        self.retryDelay = retryDelay
        self.delivery = delivery
    }
}

public enum TelegramBotError: Error, Equatable, Sendable {
    case alreadyRunning
    case connectionsAlreadySubscribed
}

/// The Telegram bot adapter.
///
/// It owns the one physical long-polling loop, offset persistence, update
/// normalization, and the logical per-chat connections. Its connection stream
/// is a work stream with one consumer; it is not a broadcast mechanism.
public actor TelegramBot {
    public typealias IDFactory = @Sendable () -> (MessageID, TurnID)
    public typealias ConnectionStream = AsyncStream<TelegramConnection>

    private let client: TelegramAPIClient
    private let allowedChatIDs: Set<Int64>
    private let offsetStore: any TelegramOffsetStore
    private let configuration: TelegramBotConfiguration
    private let idFactory: IDFactory
    private let publisher: TelegramEventPublisher
    private let logger: Logger
    private let connectionStream: ConnectionStream
    private let connectionContinuation: ConnectionStream.Continuation
    private var activeConnections: [ConversationID: TelegramConnection] = [:]
    private var connectionsSubscribed = false
    private var runTask: Task<Void, any Error>?

    public init(
        client: TelegramAPIClient,
        allowedChatIDs: Set<Int64> = [],
        offsetStore: any TelegramOffsetStore,
        configuration: TelegramBotConfiguration = TelegramBotConfiguration(),
        idFactory: @escaping IDFactory = { (MessageID(), TurnID()) },
        logger: Logger = Logger(label: "norby.telegram")
    ) {
        self.client = client
        self.allowedChatIDs = allowedChatIDs
        self.offsetStore = offsetStore
        self.configuration = configuration
        self.idFactory = idFactory
        self.publisher = TelegramEventPublisher(
            client: client,
            delivery: configuration.delivery
        )
        self.logger = logger
        (self.connectionStream, self.connectionContinuation) =
            ConnectionStream.makeStream()
    }

    /// Returns the bot's single connection stream.
    public func connections() throws -> ConnectionStream {
        guard !connectionsSubscribed else {
            throw TelegramBotError.connectionsAlreadySubscribed
        }
        connectionsSubscribed = true
        return connectionStream
    }

    /// Runs the bot's one long-polling loop.
    public func run() async throws {
        guard runTask == nil else {
            throw TelegramBotError.alreadyRunning
        }

        let task = Task { [self] in
            try await poll()
        }
        runTask = task

        do {
            try await task.value
        } catch is CancellationError {
            await finishConnections()
            runTask = nil
            return
        } catch {
            await finishConnections()
            runTask = nil
            throw error
        }

        await finishConnections()
        runTask = nil
    }

    /// Cancels polling and closes every logical connection.
    public func stop() async {
        runTask?.cancel()
        await finishConnections()
    }

    /// Recreates a logical chat connection so the application can resume
    /// durable work even when Telegram has no new update to deliver.
    public func connect(conversationID: ConversationID) async -> Bool {
        guard conversationID.channel == ChannelID("telegram"),
            let chatID = Int64(conversationID.externalAddress.rawValue),
            allowedChatIDs.isEmpty || allowedChatIDs.contains(chatID)
        else {
            return false
        }

        return await connection(for: conversationID).connect()
    }

    public static func conversationID(for chatID: Int64) -> ConversationID {
        ConversationID(
            channel: ChannelID("telegram"),
            externalAddress: ExternalConversationAddress(String(chatID))
        )
    }

    public static func participantID(for telegramUserID: Int64) -> ParticipantID {
        ParticipantID(
            channel: ChannelID("telegram"),
            rawValue: String(telegramUserID)
        )
    }

    public static func capabilities(for chat: TelegramChat) -> ChannelCapabilities {
        ChannelCapabilities(
            supportsDrafts: chat.type == "private",
            supportsTyping: true,
            maximumTextLength: 4_096,
            supportsThreads: false
        )
    }

    public static func event(
        for update: TelegramUpdate,
        messageID: MessageID,
        turnID: TurnID,
        attachments: [Attachment] = []
    ) -> TelegramInboundEvent? {
        guard let message = update.message,
            let sender = message.from
        else {
            return nil
        }

        let text = message.text ?? message.caption ?? ""
        guard
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty
        else {
            return nil
        }

        let conversationID = conversationID(for: message.chat.id)
        let participantID = participantID(for: sender.id)
        let userID = UserID(participantID: participantID)
        let displayName = [sender.firstName, sender.lastName]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " ")
        let author = MessageAuthor(
            displayName: displayName.isEmpty ? nil : displayName,
            handle: sender.username
        )
        switch command(in: text) {
        case "/start":
            return .start(
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )
        case "/reset":
            return .reset(
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )
        case "/memory":
            return .memory(
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )
        case "/forget":
            return .forget(
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )
        case "/context":
            return .context(
                conversationID: conversationID,
                participantID: participantID,
                userID: userID
            )
        default:
            return .message(
                InboundMessage(
                    id: messageID,
                    conversationID: conversationID,
                    participantID: participantID,
                    userID: userID,
                    author: author,
                    text: text,
                    attachments: attachments,
                    receivedAt: Date(timeIntervalSince1970: TimeInterval(message.date))
                ),
                telegramMessageID: message.messageID,
                turnID: turnID,
                capabilities: capabilities(for: message.chat)
            )
        }
    }

    private func poll() async throws {
        var offset = try await offsetStore.load()
        let updates = client.updates(
            startingAt: offset,
            timeout: configuration.timeout,
            retryDelay: configuration.retryDelay,
            logger: logger
        )

        var iterator = updates.makeAsyncIterator()
        while let update = try await iterator.next() {
            try Task.checkCancellation()

            let ids = idFactory()
            if let chatID = update.message?.chat.id,
                allowedChatIDs.isEmpty || allowedChatIDs.contains(chatID)
            {
                let attachments = attachments(for: update.message)
                if let event = Self.event(
                    for: update,
                    messageID: ids.0,
                    turnID: ids.1,
                    attachments: attachments
                ) {
                    let connection = connection(for: event.conversationID)
                    let accepted = await connection.receive(event)
                    if !accepted {
                        iterator.retryPendingUpdate()
                        logger.warning(
                            "Telegram input was rejected; retrying the uncheckpointed update"
                        )
                        try await Task.sleep(for: configuration.retryDelay)
                        continue
                    }
                }
            }

            // Acknowledging ignored updates is important too; otherwise
            // disallowed or non-message updates replay on every restart.
            guard update.updateID < Int64.max else { continue }
            let nextOffset = update.updateID + 1
            guard offset == nil || nextOffset > offset! else { continue }
            try await offsetStore.save(nextOffset)
            offset = nextOffset
        }
    }

    private func attachments(for message: TelegramMessage?) -> [Attachment] {
        guard let message else { return [] }

        var attachments: [Attachment] = []

        if let photo = message.photo?.max(by: { lhs, rhs in
            Int64(lhs.width) * Int64(lhs.height)
                < Int64(rhs.width) * Int64(rhs.height)
        }) {
            attachments.append(
                Attachment(
                    id: AttachmentID(
                        channel: ChannelID("telegram"),
                        externalID: photo.fileID
                    ),
                    kind: .image,
                    mimeType: "image/jpeg"
                )
            )
        }

        if let document = message.document {
            attachments.append(
                Attachment(
                    id: AttachmentID(
                        channel: ChannelID("telegram"),
                        externalID: document.fileID
                    ),
                    kind: document.mimeType?.hasPrefix("image/") == true ? .image : .file,
                    filename: document.filename,
                    mimeType: document.mimeType
                )
            )
        }

        return attachments
    }

    private func connection(for conversationID: ConversationID) -> TelegramConnection {
        if let connection = activeConnections[conversationID] {
            return connection
        }
        let connection = TelegramConnection(
            conversationID: conversationID,
            publisher: publisher,
            logger: logger
        )
        activeConnections[conversationID] = connection
        connectionContinuation.yield(connection)
        return connection
    }

    public func remove(connectionID: String) async {
        guard let entry = activeConnections.first(where: { $0.value.id == connectionID }) else {
            return
        }
        activeConnections.removeValue(forKey: entry.key)
        await entry.value.finish()
    }

    private func finishConnections() async {
        connectionContinuation.finish()
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        for connection in connections {
            await connection.finish()
        }
    }

    private static func command(in text: String) -> String? {
        guard
            let firstWord =
                text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .first,
            firstWord.first == "/"
        else {
            return nil
        }

        let command = firstWord.dropFirst().split(separator: "@", maxSplits: 1).first ?? ""
        return "/" + command.lowercased()
    }
}

extension TelegramInboundEvent {
    fileprivate var conversationID: ConversationID {
        switch self {
        case .message(let message, _, _, _): message.conversationID
        case .start(let conversationID, _, _): conversationID
        case .reset(let conversationID, _, _): conversationID
        case .memory(let conversationID, _, _): conversationID
        case .forget(let conversationID, _, _): conversationID
        case .context(let conversationID, _, _): conversationID
        }
    }
}
