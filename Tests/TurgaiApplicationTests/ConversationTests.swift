import AnyLanguageModel
import Testing
import TurgaiDomain
import TurgaiMemory
import TurgaiPeople

@testable import TurgaiApplication
@testable import TurgaiConversations

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

struct ConversationTests {
    private let conversationID = ConversationID(
        channel: ChannelID("test"),
        externalAddress: ExternalConversationAddress("chat")
    )
    /// The bot that answers in these turns.
    private let answering = BotID()

    @Test
    func conversationRecordOwnsQueueAndTurnLifecycle() {
        let participantID = ParticipantID("user")
        let first = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: participantID,
                userID: .ann,
                text: "first",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            turnID: TurnID(),
            bot: answering
        )
        let second = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: participantID,
                userID: .ann,
                text: "second",
                receivedAt: Date(timeIntervalSince1970: 2)
            ),
            turnID: TurnID(),
            bot: answering
        )

        var record = ConversationState(conversationID: conversationID)
        record.apply(.inbox(.turnStarted(first)))
        record.apply(.inbox(.queued(second)))

        #expect(record.inbox.status == .running(first.turnID))
        #expect(record.inbox.activeMessage == first)
        #expect(record.inbox.pendingMessages == [second])
        #expect(record.requiresRecovery)

        let reply = PendingConversationReply(
            turnID: first.turnID,
            reply: ConversationReply("answer")!,
            agentTurn: AgentTurnID(rawValue: "agent-turn"),
            at: Date(timeIntervalSince1970: 2)
        )
        record.apply(.replyQueued(reply))
        #expect(record.inbox.status == .idle)
        #expect(record.inbox.activeMessage == nil)
        #expect(record.inbox.pendingMessages == [second])
        #expect(record.pendingReplies == [reply])

        // The later lifecycle event is harmless when replayed after the
        // reply queue event already closed the turn.
        record.apply(.inbox(.turnCompleted(first.turnID)))
        record.apply(.replyDelivered(first.turnID))
        #expect(record.pendingReplies.isEmpty)
    }

    /// A noted message keeps its mark until it's taken off: one a restart leaves is still known, to
    /// take off with the next message.
    @Test
    func aNotedMessageIsKeptUntilItsMarkIsTakenOff() {
        var record = ConversationState(conversationID: conversationID)
        let noted = NotedMessage(id: MessageID(), channelID: ChannelMessageID(rawValue: "123"))
        record.apply(.noted(noted))
        #expect(record.noted == noted)
        record.apply(.unnoted)
        #expect(record.noted == nil)
    }

    /// `/memory` shows what's remembered, with a button to forget each fact, one to turn memory off
    /// or on, and one to forget everything when anything is remembered.
    @Test
    func memoryIsShownWithItsButtons() {
        let fact = MemoryFact(
            id: MemoryFactID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            relation: .livesIn,
            to: MemoryName("Haar, Germany")!,
            learned: Said(observation: ObservationID(), at: Date(timeIntervalSince1970: 1))
        )
        let remembered = Remembered([fact])
        #expect(MemoryPresentation.text(remembered, remembering: .on) == "Remembered:\nLives in: Haar, Germany")
        #expect(
            MemoryPresentation.actions(for: remembered, remembering: .on).map(\.command) == [
                "/forget-fact 00000000-0000-0000-0000-000000000001", "/memory-off", "/forget",
            ])
        #expect(
            MemoryPresentation.actions(for: remembered, remembering: .on).first?.label
                == "Forget Lives in: Haar, Germany")
        #expect(
            MemoryPresentation.text(Remembered([]), remembering: .off)
                == "Memory is off: nothing new is remembered.\nNothing is remembered.")
        #expect(MemoryPresentation.actions(for: Remembered([]), remembering: .off).map(\.label) == ["Turn memory on"])
    }

    /// Only its people add someone: a person, or a bot while it has none; never a guest, either
    /// way. Adding someone in it already changes nothing.
    @Test
    func onlyItsPeopleAddSomeone() throws {
        var record = ConversationState(conversationID: conversationID)
        for event in try record.starting(with: BotID(), by: .ann) {
            record.apply(event)
        }
        #expect(throws: ConversationRefusal.notInIt) { try record.adding(.person(.cat), by: .bob) }
        #expect(throws: ConversationRefusal.guestsStayOut) { try record.adding(.person(.guest(UUID())), by: .ann) }
        #expect(throws: ConversationRefusal.oneBotForNow) { try record.adding(.bot(BotID()), by: .ann) }

        for event in try record.adding(.person(.bob), by: .ann) { record.apply(event) }
        #expect(record.people == [.ann, .bob])
        #expect(try record.adding(.person(.bob), by: .ann).isEmpty)
    }

    /// What's said is kept with who said it: the person who wrote it, and the agent that answered.
    @Test
    func historyKeepsWhoSaidIt() throws {
        var record = ConversationState(conversationID: conversationID)
        let agent = BotID()
        for event in try record.starting(with: agent, by: .ann) { record.apply(event) }
        let asked = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID, participantID: ParticipantID("ann"), userID: .ann,
                text: "plan dinner", receivedAt: Date(timeIntervalSince1970: 1)),
            turnID: TurnID(), bot: agent)
        record.apply(.inbox(.turnStarted(asked)))
        record.apply(
            .replyQueued(
                PendingConversationReply(
                    turnID: asked.turnID, reply: ConversationReply("pasta")!,
                    agentTurn: AgentTurnID(rawValue: "agent-turn"), at: Date(timeIntervalSince1970: 2))))
        #expect(record.history.map(\.author) == [.person(.ann), .bot(agent)])
    }

    /// Who a message is said to decides who answers: its agent, when it's said to no one in
    /// particular or to the agent too; no one, when it's said only to people, which is kept once.
    /// Said to someone not in it, it's refused.
    @Test
    func whoAMessageIsSaidToDecidesWhoAnswers() throws {
        var record = ConversationState(conversationID: conversationID)
        let agent = BotID()
        for event in try record.starting(with: agent, by: .ann) { record.apply(event) }
        for event in try record.adding(.person(.bob), by: .ann) { record.apply(event) }
        func said(to people: Set<Participant>) -> InboundMessage {
            InboundMessage(
                conversationID: conversationID, participantID: ParticipantID("ann"), userID: .ann, text: "pasta?",
                receivedAt: Date(timeIntervalSince1970: 1), to: people)
        }

        #expect(try record.answers(said(to: [])))
        #expect(try record.answers(said(to: [.bot(agent), .person(.bob)])))
        #expect(try !record.answers(said(to: [.person(.bob)])))
        #expect(throws: ConversationRefusal.addresseeNotInIt) { try record.answers(said(to: [.person(.cat)])) }

        let toBob = said(to: [.person(.bob)])
        for event in record.saying(toBob) { record.apply(event) }
        #expect(record.history.last?.author == .person(.ann))
        #expect(record.history.last?.to == [.person(.bob)])
        #expect(record.saying(toBob).isEmpty)
    }

    @Test
    func failedConversationDoesNotAutomaticallyRetry() {
        var record = ConversationState(conversationID: conversationID)
        let message = PendingConversationMessage(
            message: InboundMessage(
                conversationID: conversationID,
                participantID: ParticipantID("user"),
                userID: .ann,
                text: "hello",
                receivedAt: Date(timeIntervalSince1970: 1)
            ),
            turnID: TurnID(),
            bot: answering
        )
        record.apply(.inbox(.turnStarted(message)))
        record.apply(
            .inbox(
                .turnFailed(
                    message.turnID, ConversationFailure(kind: .model, message: "unavailable"), agentTurn: nil,
                    at: Date(timeIntervalSince1970: 2)))
        )

        #expect(!record.requiresRecovery)
    }

    /// A new person remembers what they say; a guest, whom no one signed in as, doesn't.
    @Test
    func aGuestRemembersNothing() {
        #expect(UserRecord(userID: .ann).memory.remembering == .on)
        #expect(UserRecord(userID: .guest(UUID())).memory.remembering == .off)
    }
}
