import Logging
import NorbyDomain
import NorbyTelegram
import Testing

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct TelegramTests {
    @Test
    func botMapsMemoryCommandsToTheRequestingUser() {
        let user = TelegramUser(id: 7, firstName: "John")
        let chat = TelegramChat(id: 42)
        let participantID = TelegramBot.participantID(for: user.id)
        let userID = UserID(participantID: participantID)

        let memory = TelegramBot.event(
            for: TelegramUpdate(
                updateID: 1,
                message: TelegramMessage(
                    messageID: 1,
                    from: user,
                    chat: chat,
                    date: 100,
                    text: "/memory"
                )
            ),
            messageID: MessageID(rawValue: UUID()),
            turnID: TurnID()
        )
        let forget = TelegramBot.event(
            for: TelegramUpdate(
                updateID: 2,
                message: TelegramMessage(
                    messageID: 2,
                    from: user,
                    chat: chat,
                    date: 101,
                    text: "/forget"
                )
            ),
            messageID: MessageID(rawValue: UUID()),
            turnID: TurnID()
        )

        #expect(
            memory
                == .memory(
                    conversationID: TelegramBot.conversationID(for: chat.id),
                    participantID: participantID,
                    userID: userID
                )
        )
        #expect(
            forget
                == .forget(
                    conversationID: TelegramBot.conversationID(for: chat.id),
                    participantID: participantID,
                    userID: userID
                )
        )
    }

    @Test
    func botCanRestoreAConversationWithoutATelegramUpdate() async throws {
        let bot = TelegramBot(
            client: makeClient(recorder: TelegramCallRecorder(responses: [])),
            offsetStore: InMemoryTelegramOffsetStore()
        )
        let conversationID = TelegramBot.conversationID(for: 42)
        let connectionStream = try await bot.connections()
        let consumer = Task { () -> ConversationInput? in
            for await connection in connectionStream {
                let inbound = await connection.inbound
                for await delivery in inbound {
                    await delivery.receipt.acknowledge()
                    return delivery.input
                }
            }
            return nil
        }

        #expect(await bot.connect(conversationID: conversationID))
        #expect(await consumer.value == .connect(conversationID))
        await bot.stop()
    }

    @Test
    func botNormalizesCommandsFiltersChatsAndReportsOffsets() async throws {
        let chat = TelegramChat(id: 42)
        let user = TelegramUser(
            id: 7,
            firstName: "John",
            lastName: "Appleseed",
            username: "johnappleseed"
        )
        let updates = [
            TelegramUpdate(
                updateID: 10,
                message: TelegramMessage(
                    messageID: 1,
                    from: user,
                    chat: chat,
                    date: 100,
                    text: "/start@norby_bot"
                )
            ),
            TelegramUpdate(
                updateID: 11,
                message: TelegramMessage(
                    messageID: 2,
                    from: user,
                    chat: chat,
                    date: 101,
                    text: "hello Norby"
                )
            ),
            TelegramUpdate(
                updateID: 12,
                message: TelegramMessage(
                    messageID: 3,
                    from: user,
                    chat: chat,
                    date: 102,
                    text: "/RESET extra"
                )
            ),
            TelegramUpdate(
                updateID: 13,
                message: TelegramMessage(
                    messageID: 4,
                    from: user,
                    chat: TelegramChat(id: 999),
                    date: 103,
                    text: "ignored"
                )
            ),
            TelegramUpdate(updateID: 14),
        ]
        let recorder = TelegramCallRecorder(responses: [updates])
        let client = makeClient(recorder: recorder)
        let offsets = InMemoryTelegramOffsetStore()
        let bot = TelegramBot(
            client: client,
            allowedChatIDs: [42],
            offsetStore: offsets,
            configuration: TelegramBotConfiguration(
                timeout: 1,
                retryDelay: .milliseconds(1)
            ),
            idFactory: {
                return (
                    MessageID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
                    TurnID(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
                )
            }
        )

        let connectionStream = try await bot.connections()
        await #expect(throws: TelegramBotError.connectionsAlreadySubscribed) {
            _ = try await bot.connections()
        }

        let consumer = Task { () -> [ConversationInput] in
            var received: [ConversationInput] = []
            for await connection in connectionStream {
                let inbound = await connection.inbound
                for await delivery in inbound {
                    received.append(delivery.input)
                    await delivery.receipt.acknowledge()
                    if received.count == 2 {
                        return received
                    }
                }
            }
            return received
        }
        let runTask = Task { try await bot.run() }

        let received = await consumer.value
        #expect(received.count == 2)
        let participantID = TelegramBot.participantID(for: 7)
        let userID = UserID(participantID: participantID)
        if case .message(let message, _) = received[0] {
            #expect(message.text == "hello Norby")
            #expect(message.participantID == participantID)
            #expect(message.userID == userID)
            #expect(
                message.author
                    == MessageAuthor(
                        displayName: "John Appleseed",
                        handle: "johnappleseed"
                    )
            )
            #expect(message.receivedAt == Date(timeIntervalSince1970: 101))
        } else {
            Issue.record("Expected the first application input to be a message")
        }
        #expect(received[1] == .reset(TelegramBot.conversationID(for: 42)))

        // The bot persists offsets after processing every update, including
        // updates that are filtered out before reaching a connection.
        let deadline = Date().addingTimeInterval(2)
        var requestedOffsets = await recorder.requestedOffsets
        while Date() < deadline,
            !requestedOffsets.contains(where: { $0 == 15 })
        {
            try await Task.sleep(for: .milliseconds(10))
            requestedOffsets = await recorder.requestedOffsets
        }
        #expect(requestedOffsets.first! == nil)
        #expect(requestedOffsets.contains(15))
        #expect(await offsets.currentOffset == 15)
        await bot.stop()
        _ = try? await runTask.value
    }

    @Test
    func updateIteratorRetriesPendingUpdateWithoutAdvancingProviderOffset() async throws {
        let update = TelegramUpdate(updateID: 42)
        let recorder = TelegramCallRecorder(responses: [[update]])
        let client = makeClient(recorder: recorder)
        var iterator = client.updates(
            startingAt: nil,
            timeout: 1,
            retryDelay: .milliseconds(1),
            logger: Logger(label: "test")
        ).makeAsyncIterator()

        let first = try await iterator.next()
        iterator.retryPendingUpdate()
        let retry = try await iterator.next()

        #expect(first == update)
        #expect(retry == update)
        #expect(await recorder.requestedOffsets == [nil])
    }

    @Test
    func updateIteratorDoesNotRetryAuthenticationFailures() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        await recorder.failGetUpdates(with: .httpStatus(401))
        let client = makeClient(recorder: recorder)
        var iterator = client.updates(
            startingAt: nil,
            timeout: 1,
            retryDelay: .milliseconds(1),
            logger: Logger(label: "test")
        ).makeAsyncIterator()

        await #expect(throws: TelegramAPIError.httpStatus(401)) {
            _ = try await iterator.next()
        }

        #expect(await recorder.requestedOffsets == [nil])
    }

    @Test
    func botStopsWhenTelegramRejectsItsToken() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        await recorder.failGetUpdates(with: .httpStatus(401))
        let bot = TelegramBot(
            client: makeClient(recorder: recorder),
            offsetStore: InMemoryTelegramOffsetStore(),
            configuration: TelegramBotConfiguration(
                timeout: 1,
                retryDelay: .milliseconds(1)
            )
        )

        try await bot.run()

        #expect(await recorder.requestedOffsets == [nil])
    }

    @Test
    func mapperSkipsMessagesWithoutTextOrSender() {
        let update = TelegramUpdate(
            updateID: 1,
            message: TelegramMessage(
                messageID: 1,
                from: nil,
                chat: TelegramChat(id: 42),
                date: 100,
                text: "hello"
            )
        )

        #expect(
            TelegramBot.event(
                for: update,
                messageID: MessageID(),
                turnID: TurnID()
            ) == nil)
    }

    @Test
    func botKeepsPhotoFileIDOpaqueWithoutDownloadingIt() async throws {
        let update = TelegramUpdate(
            updateID: 1,
            message: TelegramMessage(
                messageID: 1,
                from: TelegramUser(id: 7),
                chat: TelegramChat(id: 42),
                date: 100,
                text: nil,
                caption: "What is this?",
                photo: [
                    TelegramPhotoSize(
                        fileID: "small",
                        fileUniqueID: "small-unique",
                        width: 100,
                        height: 100,
                        fileSize: 10
                    ),
                    TelegramPhotoSize(
                        fileID: "large",
                        fileUniqueID: "large-unique",
                        width: 1000,
                        height: 1000,
                        fileSize: 100
                    ),
                ]
            )
        )
        let recorder = TelegramCallRecorder(responses: [[update]])
        let bot = TelegramBot(
            client: makeClient(recorder: recorder),
            allowedChatIDs: [42],
            offsetStore: InMemoryTelegramOffsetStore(),
            configuration: TelegramBotConfiguration(
                timeout: 1,
                retryDelay: .milliseconds(1)
            )
        )

        let connectionStream = try await bot.connections()
        let consumer = Task { () -> ConversationInput? in
            for await connection in connectionStream {
                let inbound = await connection.inbound
                for await delivery in inbound {
                    await delivery.receipt.acknowledge()
                    return delivery.input
                }
            }
            return nil
        }
        let runTask = Task { try await bot.run() }

        let received = await consumer.value
        if case .message(let message, _) = received {
            #expect(message.text == "What is this?")
            #expect(message.attachments.count == 1)
            #expect(message.attachments.first?.kind == AttachmentKind.image)
            #expect(message.attachments.first?.id.rawValue == "telegram:large")
            #expect(message.attachments.first?.mimeType == "image/jpeg")
        } else {
            Issue.record("Expected an attachment message")
        }
        #expect(await recorder.requestedFileIDs.isEmpty)

        await bot.stop()
        _ = await runTask.result
    }

    @Test
    func publisherRendersScopedReplyLifecycleAndSplitsLongReplies() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        let publisher = TelegramEventPublisher(
            client: makeClient(recorder: recorder),
            maximumTextLength: 3,
            delivery: TelegramDeliveryConfiguration(
                minimumDraftInterval: .zero,
                minimumTypingActionInterval: .zero
            )
        )
        let conversationID = TelegramBot.conversationID(for: 42)
        let turnID = TurnID()
        await publisher.setDraftsEnabled(true, for: conversationID)

        try await publisher.publish(
            .reply(
                .started(
                    conversationID: conversationID,
                    turnID: turnID
                )))
        try await publisher.publish(
            .reply(
                .keepAlive(
                    conversationID: conversationID,
                    turnID: turnID,
                    phase: .thinking
                )))
        try await publisher.publish(
            .reply(
                .phase(
                    conversationID: conversationID,
                    turnID: turnID,
                    phase: .typing
                )))
        try await publisher.publish(
            .reply(
                .partial(
                    conversationID: conversationID,
                    turnID: turnID,
                    text: "ab"
                )))
        try await publisher.publish(
            .reply(
                .partial(
                    conversationID: conversationID,
                    turnID: turnID,
                    text: "abcdef"
                )))
        try await publisher.publish(
            .reply(
                .keepAlive(
                    conversationID: conversationID,
                    turnID: turnID,
                    phase: .typing
                )))
        try await publisher.publish(
            .reply(
                .finished(
                    conversationID: conversationID,
                    turnID: turnID,
                    text: "abcdef"
                )))

        #expect(
            await recorder.sentActions == [
                "typing",
                "typing",
                "typing",
                "typing",
            ])
        #expect(await recorder.sentDrafts == ["ab", "abc", "abc"])
        #expect(await recorder.sentDraftIDs.count == 3)
        #expect(await recorder.sentDraftIDs[0] == recorder.sentDraftIDs[1])
        #expect(await recorder.sentDraftIDs[1] == recorder.sentDraftIDs[2])
        #expect(await recorder.sentMessages == ["abc", "def"])
        #expect(await recorder.sentParseModes == [.html, .html])
    }

    @Test
    func publisherKeepsTheDraftPrefixStableAroundMarkdown() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        let publisher = TelegramEventPublisher(
            client: makeClient(recorder: recorder),
            delivery: TelegramDeliveryConfiguration(
                minimumDraftInterval: .zero,
                minimumTypingActionInterval: .zero
            )
        )
        let conversationID = TelegramBot.conversationID(for: 42)
        let turnID = TurnID()
        await publisher.setDraftsEnabled(true, for: conversationID)

        try await publisher.publish(
            .reply(
                .partial(
                    conversationID: conversationID,
                    turnID: turnID,
                    text: "The **weather"
                )))
        try await publisher.publish(
            .reply(
                .partial(
                    conversationID: conversationID,
                    turnID: turnID,
                    text: "The **weather** is clear"
                )))

        #expect(
            await recorder.sentDrafts == [
                "The ",
                "The <b>weather</b> is clear",
            ])
        #expect(await recorder.sentDraftIDs.count == 2)
        #expect(await recorder.sentDraftIDs[0] == recorder.sentDraftIDs[1])
    }

    @Test
    func publisherRepliesToTheMessageThatStartedTheTurn() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        let publisher = TelegramEventPublisher(
            client: makeClient(recorder: recorder),
            delivery: TelegramDeliveryConfiguration(
                minimumTypingActionInterval: .zero
            )
        )
        let conversationID = TelegramBot.conversationID(for: 42)
        let turnID = TurnID()
        await publisher.setDraftsEnabled(true, for: conversationID)

        try await publisher.markSeen(
            conversationID: conversationID,
            telegramMessageID: 123,
            turnID: turnID
        )
        try await publisher.publish(
            .reply(
                .started(
                    conversationID: conversationID,
                    turnID: turnID
                )))
        try await publisher.publish(
            .reply(
                .phase(
                    conversationID: conversationID,
                    turnID: turnID,
                    phase: .typing
                )))
        try await publisher.publish(
            .reply(
                .finished(
                    conversationID: conversationID,
                    turnID: turnID,
                    text: "done"
                )))

        #expect(await recorder.sentActions == ["typing", "typing"])
        #expect(await recorder.reactionMessageIDs == [123, 123, 123, 123])
        #expect(await recorder.sentReactions == [.seen, .thinking, .typing, nil])
        #expect(await recorder.sentMessages == ["done"])
        #expect(await recorder.sentReplyMessageIDs == [123])
    }

    @Test
    func publisherSurfacesRateLimitedDrafts() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        await recorder.rateLimitNextDrafts(1)
        let publisher = TelegramEventPublisher(
            client: makeClient(recorder: recorder),
            delivery: TelegramDeliveryConfiguration(
                minimumDraftInterval: .zero,
                fallbackRateLimitDelay: .milliseconds(1)
            )
        )
        let conversationID = TelegramBot.conversationID(for: 42)
        let turnID = TurnID()
        await publisher.setDraftsEnabled(true, for: conversationID)

        await #expect(throws: TelegramAPIError.rateLimited(retryAfter: .milliseconds(1))) {
            try await publisher.publish(
                .reply(
                    .partial(
                        conversationID: conversationID,
                        turnID: turnID,
                        text: "hello"
                    )))
        }

        #expect(await recorder.draftAttempts == 1)
        #expect(await recorder.sentDrafts.isEmpty)
    }

    @Test
    func publisherDeliversFailuresAsTerminalMessages() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        let publisher = TelegramEventPublisher(client: makeClient(recorder: recorder))
        let conversationID = TelegramBot.conversationID(for: 42)
        let turnID = TurnID()

        try await publisher.publish(
            .reply(
                .failed(
                    conversationID: conversationID,
                    turnID: turnID,
                    message: "Something went wrong."
                )))

        #expect(await recorder.sentMessages == ["Something went wrong."])
        #expect(await recorder.sentReplyMessageIDs == [nil])
    }

    @Test
    func apiClientRejectsEmptyToken() {
        #expect(throws: TelegramAPIConfigurationError.emptyToken) {
            try TelegramAPIClient.live(token: "")
        }
    }
}

private func makeClient(recorder: TelegramCallRecorder) -> TelegramAPIClient {
    TelegramAPIClient(
        getUpdates: { offset, timeout in
            try await recorder.getUpdates(offset: offset, timeout: timeout)
        },
        downloadFile: { fileID in
            await recorder.downloadFile(fileID: fileID)
        },
        sendChatAction: { _, action in
            await recorder.recordAction(action)
        },
        setMessageReaction: { chatID, messageID, reaction in
            await recorder.recordReaction(
                chatID: chatID,
                messageID: messageID,
                reaction: reaction
            )
        },
        sendMessageDraft: { _, draftID, text, parseMode in
            try await recorder.sendDraft(
                draftID: draftID,
                text: text,
                parseMode: parseMode
            )
        },
        sendMessage: { chatID, text, parseMode, replyParameters in
            await recorder.sendMessage(
                chatID: chatID,
                text: text,
                parseMode: parseMode,
                replyParameters: replyParameters
            )
        },
        editMessageText: { _, _, text, parseMode in
            try await recorder.recordEdit(text, parseMode: parseMode)
        }
    )
}

private func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private actor TelegramCallRecorder {
    private var responses: [[TelegramUpdate]]
    private var getUpdatesError: TelegramAPIError?
    private var draftsSupported = true
    private var rateLimitedDrafts = 0
    private(set) var draftAttempts = 0
    private(set) var requestedOffsets: [Int64?] = []
    private(set) var requestedFileIDs: [String] = []
    private(set) var sentActions: [String] = []
    private(set) var sentReactions: [TelegramReaction?] = []
    private(set) var reactionMessageIDs: [Int64] = []
    private(set) var sentMessages: [String] = []
    private(set) var sentReplyMessageIDs: [Int64?] = []
    private(set) var editedMessages: [String] = []
    private(set) var sentDrafts: [String] = []
    private(set) var sentDraftIDs: [Int64] = []
    private(set) var sentParseModes: [TelegramParseMode?] = []
    private(set) var draftParseModes: [TelegramParseMode?] = []
    private(set) var editedParseModes: [TelegramParseMode?] = []

    init(responses: [[TelegramUpdate]]) {
        self.responses = responses
    }

    func failGetUpdates(with error: TelegramAPIError) {
        getUpdatesError = error
    }

    func setDraftsSupported(_ supported: Bool) {
        draftsSupported = supported
    }

    func rateLimitNextDrafts(_ count: Int) {
        rateLimitedDrafts = max(0, count)
    }

    func getUpdates(offset: Int64?, timeout: Int) async throws -> [TelegramUpdate] {
        requestedOffsets.append(offset)
        if let getUpdatesError {
            throw getUpdatesError
        }
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        try await Task.sleep(for: .seconds(60))
        return []
    }

    func downloadFile(fileID: String) -> TelegramFileData {
        requestedFileIDs.append(fileID)
        return TelegramFileData(
            body: Data("file:\(fileID)".utf8),
            contentType: "application/octet-stream"
        )
    }

    func recordAction(_ action: String) {
        sentActions.append(action)
    }

    func recordReaction(chatID: Int64, messageID: Int64, reaction: TelegramReaction?) {
        #expect(chatID == 42)
        reactionMessageIDs.append(messageID)
        sentReactions.append(reaction)
    }

    func sendDraft(
        draftID: Int64,
        text: String,
        parseMode: TelegramParseMode?
    ) throws {
        draftAttempts += 1
        draftParseModes.append(parseMode)
        if rateLimitedDrafts > 0 {
            rateLimitedDrafts -= 1
            throw TelegramAPIError.rateLimited(retryAfter: .milliseconds(1))
        }
        guard draftsSupported else {
            throw TelegramAPIError.api(code: 400, message: "Bad Request: drafts are not supported")
        }
        sentDraftIDs.append(draftID)
        sentDrafts.append(text)
    }

    func sendMessage(
        chatID: Int64,
        text: String,
        parseMode: TelegramParseMode?,
        replyParameters: TelegramReplyParameters?
    ) -> TelegramMessage {
        sentMessages.append(text)
        sentParseModes.append(parseMode)
        sentReplyMessageIDs.append(replyParameters?.messageID)
        return TelegramMessage(
            messageID: Int64(sentMessages.count),
            from: nil,
            chat: TelegramChat(id: chatID),
            date: 0,
            text: text
        )
    }

    /// The next N edits are applied (recorded) but report a failure, as if
    /// Telegram's response got lost in transit.
    private var lostEditResponses = 0

    func loseNextEditResponses(_ count: Int) {
        lostEditResponses = count
    }

    func recordEdit(_ text: String, parseMode: TelegramParseMode?) throws {
        editedMessages.append(text)
        editedParseModes.append(parseMode)
        if lostEditResponses > 0 {
            lostEditResponses -= 1
            throw TelegramAPIError.api(code: 500, message: "Internal Server Error")
        }
    }

    /// What the chat currently shows: the latest placeholder edit, or the
    /// initial placeholder send if it has never been edited.
    var visibleText: String? {
        editedMessages.last ?? sentMessages.last
    }
}
