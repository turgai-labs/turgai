import Logging
import Testing
import TurgaiDomain

@testable import TurgaiTelegram

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct TelegramTests {
    @Test
    func aFilesTypeIsWhatTelegramSaysElseWhatItsPathSays() {
        #expect(TelegramAPIClient.contentType("image/png", ofFileAt: "photos/file_0.jpg") == "image/png")
        #expect(TelegramAPIClient.contentType("application/octet-stream", ofFileAt: "photos/file_0.jpg") == "image/jpeg")
        #expect(TelegramAPIClient.contentType(nil, ofFileAt: "documents/file_1.pdf") == "application/pdf")
        #expect(TelegramAPIClient.contentType(nil, ofFileAt: "documents/file_2") == nil)
    }

    /// Who a message is said to, as Telegram marks it: the bot, by a mention or a reply to it, is
    /// no one in particular, which its agent answers; a person, replied to or mentioned by name or
    /// by a username someone wrote under, is that person; a username no one wrote under is no one.
    @Test
    func aMessageIsSaidToWhoItMentionsOrRepliesTo() {
        let bot = TelegramUser(id: 1, isBot: true, firstName: "Turgai", username: "TurgaiBot")
        let ann = TelegramUser(id: 7, firstName: "Ann", username: "ann")
        let bob = TelegramUser(id: 8, firstName: "Bob", username: "bob")
        let group = TelegramChat(id: -100, type: "supergroup", title: "Family")
        func to(_ text: String, entities: [TelegramEntity]? = nil, replyingTo replied: TelegramUser? = nil)
            -> Set<Participant>?
        {
            let update = TelegramUpdate(
                updateID: 1,
                message: TelegramMessage(
                    messageID: 2, from: ann, chat: group, date: 100, text: text, entities: entities,
                    replyToMessage: replied.map { TelegramRepliedMessage(messageID: 1, from: $0) }))
            guard
                case .message(let message, _, _, _) = TelegramBot.event(
                    for: update, conversationChannel: ChannelID("telegram"), messageID: MessageID(), turnID: TurnID(),
                    bot: bot, usernames: ["bob": bob.id])
            else { return nil }
            return message.to
        }

        #expect(to("what's for dinner?") == [])
        #expect(to("sure", replyingTo: bot) == [])
        #expect(to("@TurgaiBot what's for dinner?", entities: [TelegramEntity(type: "mention", offset: 0, length: 10)]) == [])
        #expect(to("pasta?", replyingTo: bob) == [.person(.telegram(bob.id))])
        #expect(to("@bob pasta?", entities: [TelegramEntity(type: "mention", offset: 0, length: 4)]) == [.person(.telegram(bob.id))])
        #expect(
            to("Bob, pasta?", entities: [TelegramEntity(type: "text_mention", offset: 0, length: 3, user: bob)])
                == [.person(.telegram(bob.id))])
        #expect(to("@cat pasta?", entities: [TelegramEntity(type: "mention", offset: 0, length: 4)]) == [])
        #expect(
            to(
                "@TurgaiBot ask @bob",
                entities: [
                    TelegramEntity(type: "mention", offset: 0, length: 10), TelegramEntity(type: "mention", offset: 15, length: 4),
                ]) == [])
    }

    @Test
    func anAnswerButtonIsItsTappersAnswer() {
        let asker = TelegramUser(id: 7, firstName: "Kid")
        let tapper = TelegramUser(id: 8, firstName: "Parent")
        let chat = TelegramChat(id: 42)
        let request = AccessRequestID(UUID())
        func tap(_ answer: AccessAnswer) -> TelegramInboundEvent? {
            TelegramBot.event(
                for: TelegramUpdate(
                    updateID: 1,
                    callbackQuery: TelegramCallbackQuery(
                        id: "callback",
                        from: tapper,
                        message: TelegramMessage(messageID: 1, from: asker, chat: chat, date: 100, text: "Allow this?"),
                        data: TelegramAnswerButton.data(for: request, answer))
                ),
                conversationChannel: ChannelID("telegram"),
                messageID: MessageID(rawValue: UUID()),
                turnID: TurnID()
            )
        }

        // Whoever taps answers; the chat's space decides whether their answer counts.
        let parent = UserID.telegram(tapper.id)
        let conversationID = TelegramBot.conversationID(for: chat.id)
        for answer in [AccessAnswer.once, .always, .everyone, .no] {
            #expect(tap(answer) == .answer(conversationID: conversationID, request, answer, by: parent))
        }
        // Data that isn't a button's is no answer.
        #expect(TelegramAnswerButton.answer(in: "turgai-access:sometimes:\(request)") == nil)
    }

    /// What `/memory`'s buttons send: forgetting one fact by its id, and turning memory on or off.
    @Test
    func botMapsMemoryButtonsToTheirCommands() {
        let user = TelegramUser(id: 7, firstName: "John")
        let chat = TelegramChat(id: 42)
        let participantID = TelegramBot.participantID(for: user.id)
        let userID = UserID.telegram(user.id)
        let conversationID = TelegramBot.conversationID(for: chat.id)
        func event(_ text: String) -> TelegramInboundEvent? {
            TelegramBot.event(
                for: TelegramUpdate(
                    updateID: 1, message: TelegramMessage(messageID: 1, from: user, chat: chat, date: 100, text: text)),
                conversationChannel: ChannelID("telegram"),
                messageID: MessageID(rawValue: UUID()),
                turnID: TurnID()
            )
        }

        #expect(
            event("/forget-fact 5E8E4B9A-0000-4000-8000-000000000001")
                == .command(
                    .forgetFact(
                        id: "5E8E4B9A-0000-4000-8000-000000000001", conversationID: conversationID,
                        participantID: participantID, userID: userID)))
        #expect(
            event("/memory-off")
                == .command(.memoryOff(conversationID: conversationID, participantID: participantID, userID: userID)))
        #expect(
            event("/memory-on")
                == .command(.memoryOn(conversationID: conversationID, participantID: participantID, userID: userID)))
    }

    @Test
    func botMapsMemoryCommandsToTheRequestingUser() {
        let user = TelegramUser(id: 7, firstName: "John")
        let chat = TelegramChat(id: 42)
        let participantID = TelegramBot.participantID(for: user.id)
        let userID = UserID.telegram(user.id)

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
            conversationChannel: ChannelID("telegram"),
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
            conversationChannel: ChannelID("telegram"),
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
            conversationChannel: ChannelID("telegram"),
            initialOffset: nil,
            checkpointOffset: { _ in }
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
                    text: "/start@turgai_bot"
                )
            ),
            TelegramUpdate(
                updateID: 11,
                message: TelegramMessage(
                    messageID: 2,
                    from: user,
                    chat: chat,
                    date: 101,
                    text: "hello Turgai"
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
        let offsets = TelegramOffsetRecorder()
        let bot = TelegramBot(
            client: client,
            conversationChannel: ChannelID("telegram"),
            allowedChatIDs: [42],
            initialOffset: nil,
            checkpointOffset: { offset in await offsets.checkpoint(offset) },
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
                    if received.count == 3 {
                        return received
                    }
                }
            }
            return received
        }
        let runTask = Task { try await bot.run() }

        let received = await consumer.value
        #expect(received.count == 3)
        let participantID = TelegramBot.participantID(for: 7)
        let userID = UserID.telegram(7)
        // A private chat is called after its one person, who decides for it.
        #expect(
            received[0]
                == .chat(
                    conversationID: TelegramBot.conversationID(for: 42), named: SpaceName("John Appleseed")!,
                    admins: [userID], by: userID))
        if case .message(let message, _) = received[1] {
            #expect(message.text == "hello Turgai")
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
        #expect(received[2] == .reset(TelegramBot.conversationID(for: 42), by: userID))

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
    func aGroupsAdministratorsAreItsAdminsAndAskedForOnce() async throws {
        let group = TelegramChat(id: 42, type: "group", title: "Family")
        let ann = TelegramUser(id: 7, firstName: "Ann")
        let bob = TelegramUser(id: 8, firstName: "Bob")
        let updates = (1...2).map { index in
            TelegramUpdate(
                updateID: Int64(index),
                message: TelegramMessage(
                    messageID: Int64(index), from: bob, chat: group, date: 100, text: "hello \(index)"))
        }
        let recorder = TelegramCallRecorder(responses: [updates])
        let bot = TelegramBot(
            client: makeClient(
                recorder: recorder, administrators: [ann, TelegramUser(id: 9, isBot: true, firstName: "Turgai")]),
            conversationChannel: ChannelID("telegram"),
            allowedChatIDs: [42],
            initialOffset: nil,
            checkpointOffset: { _ in },
            configuration: TelegramBotConfiguration(timeout: 1, retryDelay: .milliseconds(1))
        )

        let connectionStream = try await bot.connections()
        let consumer = Task { () -> [ConversationInput] in
            var received: [ConversationInput] = []
            for await connection in connectionStream {
                for await delivery in await connection.inbound {
                    received.append(delivery.input)
                    await delivery.receipt.acknowledge()
                    if received.count == 3 { return received }
                }
            }
            return received
        }
        let runTask = Task { try await bot.run() }

        let received = await consumer.value
        let annID = UserID.telegram(7)
        #expect(
            received.first
                == .chat(
                    conversationID: TelegramBot.conversationID(for: 42), named: SpaceName("Family")!, admins: [annID],
                    by: .telegram(8)))
        #expect(received.dropFirst().allSatisfy { if case .message = $0 { true } else { false } })
        #expect(await recorder.administratorRequests == 1)
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
            conversationChannel: ChannelID("telegram"),
            initialOffset: nil,
            checkpointOffset: { _ in },
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
                conversationChannel: ChannelID("telegram"),
                messageID: MessageID(),
                turnID: TurnID()
            ) == nil)
    }

    /// `/link` does nothing while linking is set aside: no code is made in a chat, and none
    /// entered there links anyone.
    @Test
    func botIgnoresLink() {
        func event(_ text: String) -> TelegramInboundEvent? {
            TelegramBot.event(
                for: TelegramUpdate(
                    updateID: 1,
                    message: TelegramMessage(
                        messageID: 1, from: TelegramUser(id: 7, firstName: "Ann"),
                        chat: TelegramChat(id: 42, type: "group"), date: 100, text: text)),
                conversationChannel: ChannelID("telegram"),
                messageID: MessageID(),
                turnID: TurnID()
            )
        }

        #expect(event("/link") == nil)
        #expect(event("/link K7Q-4P2") == nil)
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
            conversationChannel: ChannelID("telegram"),
            allowedChatIDs: [42],
            initialOffset: nil,
            checkpointOffset: { _ in },
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
                    // What the chat is comes first.
                    if case .chat = delivery.input { continue }
                    return delivery.input
                }
            }
            return nil
        }
        let runTask = Task { try await bot.run() }

        let received = await consumer.value
        if case .message(let message, _) = received {
            #expect(message.text == "What is this?")
            #expect(message.channelMessageID == ChannelMessageID(rawValue: "1"))
            #expect(message.attachments.count == 1)
            #expect(message.attachments.first?.kind == AttachmentKind.image)
            #expect(message.attachments.first?.id.rawValue == "large")
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

    /// A noted message is marked by its Telegram id, and its mark is taken off again; one Telegram
    /// gave no id has none.
    @Test
    func publisherMarksANotedMessageAndTakesTheMarkOff() async throws {
        let recorder = TelegramCallRecorder(responses: [])
        let publisher = TelegramEventPublisher(client: makeClient(recorder: recorder))
        let conversationID = TelegramBot.conversationID(for: 42)
        let noted = NotedMessage(id: MessageID(), channelID: ChannelMessageID(rawValue: "123"))

        try await publisher.publish(.noted(conversationID: conversationID, noted))
        try await publisher.publish(.unnoted(conversationID: conversationID, noted))
        try await publisher.publish(
            .noted(conversationID: conversationID, NotedMessage(id: MessageID(), channelID: nil)))

        #expect(await recorder.reactionMessageIDs == [123, 123])
        #expect(await recorder.sentReactions == [.noted, nil])
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

private actor TelegramOffsetRecorder {
    private(set) var currentOffset: Int64?

    func checkpoint(_ value: Int64) {
        currentOffset = value
    }
}

private func makeClient(
    recorder: TelegramCallRecorder, administrators: [TelegramUser] = []
) -> TelegramAPIClient {
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
        },
        getChatAdministrators: { _ in
            await recorder.askedForAdministrators()
            return administrators
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
    private(set) var administratorRequests = 0
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

    func askedForAdministrators() {
        administratorRequests += 1
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
