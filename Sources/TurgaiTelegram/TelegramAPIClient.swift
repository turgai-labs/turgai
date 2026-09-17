import AsyncHTTPClient
import Logging
import NIOCore
import TurgaiDomain

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

public enum TelegramAPIConfigurationError: Error, Equatable, Sendable {
    case emptyToken
}

public enum TelegramAPIError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case rateLimited(retryAfter: Duration?)
    case api(code: Int?, message: String?)
    case missingResult(method: String)
    case missingFilePath
}

extension TelegramAPIError {
    var isAuthenticationFailure: Bool {
        switch self {
        case .httpStatus(401):
            true
        case .api(let code, _):
            code == 401
        default:
            false
        }
    }
}

public enum TelegramReaction: String, Equatable, Sendable {
    case seen = "👀"
    case thinking = "🤔"
    case typing = "👨‍💻"
}

public enum TelegramParseMode: String, Codable, Equatable, Sendable {
    case html = "HTML"
}

/// Identifies the message that a new Telegram message should reply to.
/// Editing that message later preserves the relationship.
public struct TelegramReplyParameters: Codable, Equatable, Sendable {
    public let messageID: Int64

    public init(messageID: Int64) {
        self.messageID = messageID
    }

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

public struct TelegramInlineKeyboardButton: Codable, Equatable, Sendable {
    public let text: String
    public let callbackData: String?

    public init(text: String, callbackData: String? = nil) {
        self.text = text
        self.callbackData = callbackData
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case callbackData = "callback_data"
    }
}

public struct TelegramInlineKeyboardMarkup: Codable, Equatable, Sendable {
    public let inlineKeyboard: [[TelegramInlineKeyboardButton]]

    public init(inlineKeyboard: [[TelegramInlineKeyboardButton]]) {
        self.inlineKeyboard = inlineKeyboard
    }

    private enum CodingKeys: String, CodingKey {
        case inlineKeyboard = "inline_keyboard"
    }
}

/// File bytes fetched through Telegram's authenticated file endpoint.
/// The temporary token-bearing URL is deliberately not exposed.
public struct TelegramFileData: Sendable {
    public let body: Data
    public let contentType: String?

    public init(body: Data, contentType: String? = nil) {
        self.body = body
        self.contentType = contentType
    }
}

private enum TelegramAPIMethod: String, Sendable {
    case getMe
    case getUpdates
    case getFile
    case sendChatAction
    case setMessageReaction
    case answerCallbackQuery
    case sendMessageDraft
    case sendMessage
    case editMessageText
}

/// Telegram Bot API calls as a value of closures, in the same style as
/// Hail's `OllamaTransport`: compose the live client at the boundary with
/// `.live(token:)`, inject a stub in tests.
public struct TelegramAPIClient: Sendable {
    public var getUpdates: @Sendable (_ offset: Int64?, _ timeout: Int) async throws -> [TelegramUpdate]
    public var downloadFile: @Sendable (_ fileID: String) async throws -> TelegramFileData
    public var sendChatAction: @Sendable (_ chatID: Int64, _ action: String) async throws -> Void
    public var setMessageReaction:
        @Sendable (_ chatID: Int64, _ messageID: Int64, _ reaction: TelegramReaction?) async throws -> Void
    public var answerCallbackQuery: @Sendable (_ callbackQueryID: String) async throws -> Void
    public var sendMessageDraft:
        @Sendable (_ chatID: Int64, _ draftID: Int64, _ text: String, _ parseMode: TelegramParseMode?) async throws ->
            Void
    public var sendMessage:
        @Sendable (
            _ chatID: Int64, _ text: String, _ parseMode: TelegramParseMode?,
            _ replyParameters: TelegramReplyParameters?
        ) async throws -> TelegramMessage
    public var sendMessageWithMarkup:
        @Sendable (
            _ chatID: Int64, _ text: String, _ parseMode: TelegramParseMode?,
            _ replyParameters: TelegramReplyParameters?, _ replyMarkup: TelegramInlineKeyboardMarkup?
        ) async throws -> TelegramMessage
    public var editMessageText:
        @Sendable (_ chatID: Int64, _ messageID: Int64, _ text: String, _ parseMode: TelegramParseMode?) async throws ->
            Void

    public init(
        getUpdates: @escaping @Sendable (_ offset: Int64?, _ timeout: Int) async throws -> [TelegramUpdate],
        getMe: @escaping @Sendable () async throws -> TelegramUser = {
            throw TelegramAPIError.invalidResponse
        },
        downloadFile: @escaping @Sendable (_ fileID: String) async throws -> TelegramFileData,
        sendChatAction: @escaping @Sendable (_ chatID: Int64, _ action: String) async throws -> Void,
        setMessageReaction:
            @escaping @Sendable (_ chatID: Int64, _ messageID: Int64, _ reaction: TelegramReaction?) async throws ->
            Void,
        answerCallbackQuery:
            @escaping @Sendable (_ callbackQueryID: String) async throws -> Void = { _ in },
        sendMessageDraft:
            @escaping @Sendable (_ chatID: Int64, _ draftID: Int64, _ text: String, _ parseMode: TelegramParseMode?)
            async throws -> Void,
        sendMessage:
            @escaping @Sendable (
                _ chatID: Int64, _ text: String, _ parseMode: TelegramParseMode?,
                _ replyParameters: TelegramReplyParameters?
            ) async throws -> TelegramMessage,
        sendMessageWithMarkup:
            (
                @Sendable (
                    _ chatID: Int64, _ text: String, _ parseMode: TelegramParseMode?,
                    _ replyParameters: TelegramReplyParameters?, _ replyMarkup: TelegramInlineKeyboardMarkup?
                ) async throws -> TelegramMessage
            )? = nil,
        editMessageText:
            @escaping @Sendable (_ chatID: Int64, _ messageID: Int64, _ text: String, _ parseMode: TelegramParseMode?)
            async throws -> Void
    ) {
        self.getUpdates = getUpdates
        self.getMe = getMe
        self.downloadFile = downloadFile
        self.sendChatAction = sendChatAction
        self.setMessageReaction = setMessageReaction
        self.answerCallbackQuery = answerCallbackQuery
        self.sendMessageDraft = sendMessageDraft
        self.sendMessage = sendMessage
        self.sendMessageWithMarkup =
            sendMessageWithMarkup ?? { chatID, text, parseMode, replyParameters, _ in
                try await sendMessage(chatID, text, parseMode, replyParameters)
            }
        self.editMessageText = editMessageText
    }

    private var getMe: @Sendable () async throws -> TelegramUser

    /// Verifies that the configured token is accepted by Telegram.
    public func validateToken() async throws {
        _ = try await getMe()
    }
}

/// A single-consumer stream of Telegram updates.
///
/// The iterator acknowledges an update only when the consumer asks for the
/// next one. That gives `TelegramBot` a safe boundary: it can persist its
/// application offset after handling an update, before this stream advances
/// its long-poll offset.
public struct TelegramUpdateStream: AsyncSequence, Sendable {
    public typealias Element = TelegramUpdate

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private let getUpdates: @Sendable (Int64?, Int) async throws -> [TelegramUpdate]
        private let timeout: Int
        private let retryDelay: Duration
        private let logger: Logger
        private var offset: Int64?
        private var bufferedUpdates: [TelegramUpdate] = []
        private var pendingAcknowledgement: Int64?
        private var pendingUpdate: TelegramUpdate?

        fileprivate init(
            getUpdates: @escaping @Sendable (Int64?, Int) async throws -> [TelegramUpdate],
            offset: Int64?,
            timeout: Int,
            retryDelay: Duration,
            logger: Logger
        ) {
            self.getUpdates = getUpdates
            self.offset = offset
            self.timeout = timeout
            self.retryDelay = retryDelay
            self.logger = logger
        }

        public mutating func next() async throws -> TelegramUpdate? {
            acknowledgePendingUpdate()

            while bufferedUpdates.isEmpty {
                let updates = try await nextBatch()
                bufferedUpdates =
                    updates
                    .sorted(by: { $0.updateID < $1.updateID })
                    .filter { update in
                        offset == nil || update.updateID >= offset!
                    }
            }

            try Task.checkCancellation()
            let update = bufferedUpdates.removeFirst()
            pendingAcknowledgement = update.updateID
            pendingUpdate = update
            return update
        }

        /// Puts the current update back at the head of the iterator without
        /// advancing its provider offset. The next call to `next()` returns
        /// the same update, preserving at-least-once delivery.
        public mutating func retryPendingUpdate() {
            guard let pendingUpdate, pendingAcknowledgement != nil else {
                return
            }

            pendingAcknowledgement = nil
            self.pendingUpdate = nil
            bufferedUpdates.insert(pendingUpdate, at: 0)
        }

        private mutating func acknowledgePendingUpdate() {
            guard let updateID = pendingAcknowledgement else { return }
            pendingAcknowledgement = nil
            pendingUpdate = nil

            guard updateID < Int64.max else { return }
            let nextOffset = updateID + 1
            if offset == nil || nextOffset > offset! {
                offset = nextOffset
            }
        }

        private mutating func nextBatch() async throws -> [TelegramUpdate] {
            do {
                return try await getUpdates(offset, timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TelegramAPIError where error.isAuthenticationFailure {
                throw error
            } catch {
                logger.warning("Telegram polling failed: \(error)")
                do {
                    try await Task.sleep(for: retryDelay)
                    try Task.checkCancellation()
                } catch {
                    throw CancellationError()
                }
                return try await nextBatch()
            }
        }
    }

    private let offset: Int64?
    private let timeout: Int
    private let retryDelay: Duration
    private let logger: Logger

    fileprivate init(
        getUpdates: @escaping @Sendable (Int64?, Int) async throws -> [TelegramUpdate],
        offset: Int64?,
        timeout: Int,
        retryDelay: Duration,
        logger: Logger
    ) {
        self.offset = offset
        self.timeout = timeout
        self.retryDelay = retryDelay
        self.logger = logger
        self.getUpdates = getUpdates
    }

    private let getUpdates: @Sendable (Int64?, Int) async throws -> [TelegramUpdate]

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            getUpdates: getUpdates,
            offset: offset,
            timeout: timeout,
            retryDelay: retryDelay,
            logger: logger
        )
    }
}

extension TelegramAPIClient {
    /// Creates the bot's single long-polling update sequence.
    public func updates(
        startingAt offset: Int64?,
        timeout: Int,
        retryDelay: Duration,
        logger: Logger
    ) -> TelegramUpdateStream {
        TelegramUpdateStream(
            getUpdates: getUpdates,
            offset: offset,
            timeout: max(0, timeout),
            retryDelay: retryDelay,
            logger: logger
        )
    }

    private static let httpClient: HTTPClient = {
        var configuration = HTTPClient.Configuration()
        // No read timeout: long polling intentionally holds a request open.
        configuration.timeout = .init(connect: .seconds(10), read: nil)
        return HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: configuration
        )
    }()

    public static func live(
        token: String,
        baseURL: URL = URL(string: "https://api.telegram.org")!,
        requestTimeout: TimeInterval = 15
    ) throws -> TelegramAPIClient {
        guard !token.isEmpty else {
            throw TelegramAPIConfigurationError.emptyToken
        }

        @Sendable func call<Result: Decodable & Sendable, Body: Encodable & Sendable>(
            method: TelegramAPIMethod,
            body: Body,
            result: Result.Type,
            timeout: TimeAmount
        ) async throws -> Result {
            let url =
                baseURL
                .appendingPathComponent("bot\(token)")
                .appendingPathComponent(method.rawValue)
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = .POST
            request.headers.add(name: "Content-Type", value: "application/json")
            request.body = .bytes(ByteBuffer(bytes: try JSONEncoder().encode(body)))

            let response = try await httpClient.execute(request, timeout: timeout)
            guard (200..<300).contains(response.status.code) else {
                if response.status.code == 429 {
                    let data = try await response.body.collect(upTo: 8 * 1024 * 1024)
                    let retryAfter = try? JSONDecoder()
                        .decode(TelegramAPIErrorResponse.self, from: data)
                        .parameters?.retryAfter
                        .map { Duration.seconds(Int64($0)) }
                    throw TelegramAPIError.rateLimited(retryAfter: retryAfter ?? nil)
                }
                throw TelegramAPIError.httpStatus(Int(response.status.code))
            }

            let data = try await response.body.collect(upTo: 8 * 1024 * 1024)
            let envelope = try JSONDecoder().decode(
                TelegramAPIResponse<Result>.self,
                from: data
            )
            guard envelope.ok else {
                if envelope.errorCode == 429 {
                    throw TelegramAPIError.rateLimited(
                        retryAfter: envelope.parameters?.retryAfter.map {
                            Duration.seconds(Int64($0))
                        }
                    )
                }
                throw TelegramAPIError.api(
                    code: envelope.errorCode,
                    message: envelope.description
                )
            }
            guard let value = envelope.result else {
                throw TelegramAPIError.missingResult(method: method.rawValue)
            }
            return value
        }

        @Sendable func pollRequestTimeout(forPollSeconds pollTimeout: Int) -> TimeAmount {
            .seconds(Int64(max(requestTimeout, TimeInterval(pollTimeout) + 10).rounded(.up)))
        }

        return TelegramAPIClient(
            getUpdates: { offset, timeout in
                try await call(
                    method: .getUpdates,
                    body: GetUpdatesRequest(offset: offset, timeout: timeout),
                    result: [TelegramUpdate].self,
                    timeout: pollRequestTimeout(forPollSeconds: timeout)
                )
            },
            getMe: {
                try await call(
                    method: .getMe,
                    body: EmptyTelegramRequest(),
                    result: TelegramUser.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            downloadFile: { fileID in
                let file = try await call(
                    method: .getFile,
                    body: GetFileRequest(fileID: fileID),
                    result: TelegramFile.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
                guard let filePath = file.filePath else {
                    throw TelegramAPIError.missingFilePath
                }
                let downloadURL =
                    baseURL
                    .appendingPathComponent("file")
                    .appendingPathComponent("bot\(token)")
                    .appendingPathComponent(filePath)
                let response = try await httpClient.execute(
                    HTTPClientRequest(url: downloadURL.absoluteString),
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
                guard (200..<300).contains(response.status.code) else {
                    throw TelegramAPIError.httpStatus(Int(response.status.code))
                }

                let body = try await response.body.collect(upTo: 20 * 1024 * 1024)
                let contentType = response.headers.first(name: "Content-Type")?
                    .split(separator: ";", maxSplits: 1)
                    .first
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                return TelegramFileData(
                    body: Data(body.readableBytesView),
                    contentType: contentType
                )
            },
            sendChatAction: { chatID, action in
                _ = try await call(
                    method: .sendChatAction,
                    body: SendChatActionRequest(chatID: chatID, action: action),
                    result: Bool.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            setMessageReaction: { chatID, messageID, reaction in
                _ = try await call(
                    method: .setMessageReaction,
                    body: SetMessageReactionRequest(
                        chatID: chatID,
                        messageID: messageID,
                        reaction: reaction.map {
                            [TelegramReactionType(type: "emoji", emoji: $0.rawValue)]
                        } ?? []
                    ),
                    result: Bool.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            answerCallbackQuery: { callbackQueryID in
                _ = try await call(
                    method: .answerCallbackQuery,
                    body: AnswerCallbackQueryRequest(callbackQueryID: callbackQueryID),
                    result: Bool.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            sendMessageDraft: { chatID, draftID, text, parseMode in
                _ = try await call(
                    method: .sendMessageDraft,
                    body: SendMessageDraftRequest(
                        chatID: chatID,
                        draftID: draftID,
                        text: text,
                        parseMode: parseMode
                    ),
                    result: Bool.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            sendMessage: { chatID, text, parseMode, replyParameters in
                try await call(
                    method: .sendMessage,
                    body: SendMessageRequest(
                        chatID: chatID,
                        text: text,
                        parseMode: parseMode,
                        replyParameters: replyParameters,
                        replyMarkup: nil
                    ),
                    result: TelegramMessage.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            sendMessageWithMarkup: { chatID, text, parseMode, replyParameters, replyMarkup in
                try await call(
                    method: .sendMessage,
                    body: SendMessageRequest(
                        chatID: chatID,
                        text: text,
                        parseMode: parseMode,
                        replyParameters: replyParameters,
                        replyMarkup: replyMarkup
                    ),
                    result: TelegramMessage.self,
                    timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                )
            },
            editMessageText: { chatID, messageID, text, parseMode in
                do {
                    _ = try await call(
                        method: .editMessageText,
                        body: EditMessageTextRequest(
                            chatID: chatID,
                            messageID: messageID,
                            text: text,
                            parseMode: parseMode
                        ),
                        result: TelegramMessage.self,
                        timeout: .seconds(Int64(requestTimeout.rounded(.up)))
                    )
                } catch TelegramAPIError.api(_, let message)
                    where message?.contains("not modified") == true
                {
                    // Editing a message to identical text is a Telegram no-op.
                }
            }
        )
    }
}

private struct TelegramAPIResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: Result?
    let description: String?
    let errorCode: Int?
    let parameters: TelegramAPIErrorParameters?

    private enum CodingKeys: String, CodingKey {
        case ok
        case result
        case description
        case errorCode = "error_code"
        case parameters
    }
}

private struct TelegramAPIErrorResponse: Decodable, Sendable {
    let parameters: TelegramAPIErrorParameters?
}

private struct TelegramAPIErrorParameters: Decodable, Sendable {
    let retryAfter: Int?

    private enum CodingKeys: String, CodingKey {
        case retryAfter = "retry_after"
    }
}

private struct EmptyTelegramRequest: Encodable, Sendable {}

private struct GetUpdatesRequest: Encodable, Sendable {
    let offset: Int64?
    let timeout: Int

    private enum CodingKeys: String, CodingKey {
        case offset
        case timeout
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(offset, forKey: .offset)
        try container.encode(timeout, forKey: .timeout)
    }
}

private struct GetFileRequest: Encodable, Sendable {
    let fileID: String

    private enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
    }
}

private struct TelegramFile: Decodable, Sendable {
    let filePath: String?

    private enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}

private struct SendChatActionRequest: Encodable, Sendable {
    let chatID: Int64
    let action: String

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case action
    }
}

private struct AnswerCallbackQueryRequest: Encodable, Sendable {
    let callbackQueryID: String

    private enum CodingKeys: String, CodingKey {
        case callbackQueryID = "callback_query_id"
    }
}

private struct TelegramReactionType: Encodable, Sendable {
    let type: String
    let emoji: String
}

private struct SetMessageReactionRequest: Encodable, Sendable {
    let chatID: Int64
    let messageID: Int64
    let reaction: [TelegramReactionType]

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case messageID = "message_id"
        case reaction
    }
}

private struct SendMessageRequest: Encodable, Sendable {
    let chatID: Int64
    let text: String
    let parseMode: TelegramParseMode?
    let replyParameters: TelegramReplyParameters?
    let replyMarkup: TelegramInlineKeyboardMarkup?

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
        case parseMode = "parse_mode"
        case replyParameters = "reply_parameters"
        case replyMarkup = "reply_markup"
    }
}

private struct SendMessageDraftRequest: Encodable, Sendable {
    let chatID: Int64
    let draftID: Int64
    let text: String
    let parseMode: TelegramParseMode?

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case draftID = "draft_id"
        case text
        case parseMode = "parse_mode"
    }
}

private struct EditMessageTextRequest: Encodable, Sendable {
    let chatID: Int64
    let messageID: Int64
    let text: String
    let parseMode: TelegramParseMode?

    private enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case messageID = "message_id"
        case text
        case parseMode = "parse_mode"
    }
}
